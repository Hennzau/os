# The initrd is a second, small Arch tree - the mkosi-initrd approach rather
# than mkinitcpio. It carries systemd, so mount.usr=dissect, dm-verity and the
# userspace verity signature check all run the same code as the real system.

use common.nu *
use tree.nu [bootstrap]

const PACKAGES = [systemd util-linux kmod bash coreutils]

# Enough to find and mount a /usr partition on the machines this image boots:
# virtio for VMs, NVMe/AHCI/USB for hardware, erofs and dm-verity for /usr,
# vfat for the ESP. Dependencies are resolved from modinfo, so this is only
# the list of things we actually ask for.
const MODULES = [
    virtio_blk virtio_scsi virtio_pci virtio_net
    nvme ahci sd_mod usb_storage uas xhci_pci xhci_hcd ehci_pci
    erofs dm_verity dm_mod loop
    vfat nls_cp437 nls_iso8859_1
]

# Everything the initrd has no use for. It is packed into RAM on every boot,
# so size matters here in a way it does not for /usr.
const PRUNE = [
    usr/share/doc usr/share/man usr/share/info usr/share/locale usr/share/i18n
    usr/share/zoneinfo usr/include usr/lib/pacman var/lib/pacman var/cache
    usr/lib/modules
]

def resolve-modules [tree: path, kver: string]: nothing -> list<string> {
    mut todo = $MODULES
    mut seen = []
    while ($todo | is-not-empty) {
        let m = ($todo | first)
        $todo = ($todo | skip 1)
        if $m in $seen { continue }
        $seen = ($seen | append $m)

        let deps = (^modinfo -b $tree -k $kver -F depends $m | complete)
        if $deps.exit_code != 0 { continue }
        let more = ($deps.stdout | str trim | split row "," | where { $in != "" })
        $todo = ($todo | append $more)
    }

    $seen | each { |m|
        let f = (^modinfo -b $tree -k $kver -F filename $m | complete | get stdout | str trim)
        if $f != "" and $f != "(builtin)" { $f }
    } | compact
}

def copy-modules [src: path, dst: path, kver: string] {
    let files = (resolve-modules $src $kver)
    let base = ($src | path join usr lib modules $kver)

    # Paths relative to the module tree, plus what depmod needs to rebuild
    # its maps for exactly this subset.
    # modinfo -b reports paths through the /lib -> usr/lib symlink, so strip up
    # to the modules/<kver>/ component rather than a fixed prefix.
    let rel = ($files | each { |f| $f | str replace --regex $".*/modules/($kver)/" "" })
    let meta = (ls $base | get name | path basename | where { $in =~ '^modules\.(order|builtin|builtin\.modinfo)$' })

    let list = (workspace | path join initrd-modules.txt)
    $rel | append $meta | str join "\n" | save --force $list
    let target = ($dst | path join usr lib modules $kver)
    ns-run - sh -c $"mkdir -p '($target)' && tar -C '($base)' -cf - -T '($list)' | tar -C '($target)' -xpf -"
    ns-run - depmod -b $dst $kver
    print $"  ($files | length) kernel modules"
}

# A newc cpio fragment with /dev/console, which the kernel opens before init
# runs and which cannot be created with mknod in a user namespace. Written by
# hand - newc is a fixed ASCII header, the name, and padding to four bytes.
def console-fragment [out: path] {
    ^python3 -c '
import sys
def entry(name, mode, major=0, minor=0):
    name = name.encode() + b"\0"
    # ino mode uid gid nlink mtime filesize devmajor devminor rdevmajor rdevminor namesize check
    fields = [0, mode, 0, 0, 1, 0, 0, 0, 0, major, minor, len(name), 0]
    blob = b"070701" + b"".join(b"%08X" % f for f in fields) + name
    return blob + b"\0" * (-len(blob) % 4)
out = entry("dev", 0o040755) + entry("dev/console", 0o020600, 5, 1) + entry("TRAILER!!!", 0)
sys.stdout.buffer.write(out + b"\0" * (-len(out) % 512))
' | save --force --raw $out
}

# The initrd is two archives, which the UKI concatenates and the kernel
# unpacks in order. The first is everything that comes from packages: slow to
# build, so it is rebuilt only when the kernel, the package databases or this
# file change. The second is what changes from build to build.
export def paths []: nothing -> list<path> {
    [(workspace | path join initrd.cpio.zst) (workspace | path join initrd-identity.cpio)]
}

def packaged [base: path, out: path] {
    let kver = (kernel-version $base)
    let dbs = ($base | path join var lib pacman sync)
    let key = {
        kernel: $kver
        databases: (glob ($dbs | path join *.db) | sort | each { open --raw | hash sha256 })
        recipe: (open --raw (project | path join lib initrd.nu) | hash sha256)
    } | to nuon
    let stamp = (workspace | path join initrd.key)
    if ($out | path exists) and ($stamp | path exists) and (open --raw $stamp) == $key {
        print $"  packaged part unchanged \(($kver))"
        return
    }
    rm -f $stamp

    # From the package tree's own databases: the same systemd as /usr, and
    # no download.
    let initrd = (initrd-dir)
    bootstrap $initrd $PACKAGES --dbs $dbs

    step "shaping the initrd"
    for p in $PRUNE { ns-run - rm -rf ($initrd | path join $p) }
    copy-modules $base $initrd $kver
    ns-run - ln -sf usr/lib/systemd/systemd ($initrd | path join init)

    step "packing the initrd"
    # Packed as namespace root, so every file is owned by root in the archive.
    ns-run - sh -c $"cd '($initrd)' && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc --reproducible | zstd -q -19 -T0 -f -o '($out)'"
    $key | save --force $stamp
}

# The release file - systemd decides it is in an initrd by its existence, and
# it carries IMAGE_VERSION - the verity certificate and /dev/console. Small
# and uncompressed; rebuilt every time.
def identity [tree: path, out: path] {
    let stage = (workspace | path join initrd-identity)
    rm -rf $stage
    mkdir ($stage | path join etc) ($stage | path join usr lib verity.d)
    cp ($tree | path join usr lib os-release) ($stage | path join etc initrd-release)
    cp (keys-dir | path join db.crt) ($stage | path join usr lib verity.d $"((config).id).crt")
    ^chmod -R u=rwX,go=rX $stage

    let console = (workspace | path join console.cpio)
    console-fragment $console
    let files = (workspace | path join identity-files.cpio)
    ^sh -c $"cd '($stage)' && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc --reproducible -R 0:0 > '($files)'"
    ^sh -c $"cat '($console)' '($files)' > '($out)'"
    rm $files
}

export def main [] {
    let base = (base-dir)
    let tree = (tree-dir)
    if not ($tree | path join usr lib os-release | path exists) {
        error make { msg: "no root tree - run `elv tree` first" }
    }
    let out = (paths)

    packaged $base ($out | first)
    identity $tree ($out | last)
    for f in $out { print $"  ($f) \((ls $f | get size | first))" }
}
