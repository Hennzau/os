# The root tree: a copy of the package tree, with the layers applied and /usr
# made hermetic - everything the image needs at boot must live under /usr,
# because /usr is the only thing that ships.

use common.nu *

export def pacman-conf []: nothing -> path {
    let c = (config)
    let conf = (workspace | path join pacman.conf)

    # mkosi's cache, when present, is read as an extra cache so test builds do
    # not download what this machine already has. Downloads go to the first,
    # writable CacheDir.
    let mkosi = ($env.HOME | path join ".cache/mkosi/arch~rolling~x86-64/cache/pacman/pkg")
    let extra = if ($mkosi | path exists) { $"CacheDir = ($mkosi)\n" } else { "" }

    $"[options]
Architecture = x86_64
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 8
DisableSandbox
CacheDir = (cache-dir)
($extra)
[core]
Server = ($c.mirror)/$repo/os/$arch

[extra]
Server = ($c.mirror)/$repo/os/$arch
" | save --force $conf
    $conf
}

# pacman's trust store for this workspace, populated from the host's
# archlinux-keyring. Separate from the host's, so nothing here touches /etc.
export def keyring []: nothing -> path {
    let gpg = (workspace | path join gnupg)
    if ($gpg | path join .populated | path exists) { return $gpg }

    step "initialising the pacman keyring"
    mkdir $gpg
    ns-run - pacman-key --gpgdir $gpg --init
    ns-run - pacman-key --gpgdir $gpg --populate archlinux
    touch ($gpg | path join .populated)
    $gpg
}

# What the image's fixed shape needs, whatever the layers list: mkfs.vfat,
# for the ESP systemd-sysinstall creates on the disk it installs to.
const BUILTIN_PACKAGES = [dosfstools]

export def layer-packages []: nothing -> list<string> {
    $BUILTIN_PACKAGES | append (layers
    | each { |l| $l | path join packages }
    | where { path exists }
    | each { open --raw | lines | str trim | where { |p| $p != "" and not ($p | str starts-with "#") } }
    | flatten)
    | uniq
}

# pacman on a tree, with its API filesystems mounted. `initramfs` is a virtual
# package the kernel depends on; claiming it is installed keeps mkinitcpio out
# - the initrd is built from its own tree instead.
def --wrapped pacman-in [tree: path, ...args: string] {
    (ns-run $tree pacman --root $tree --config (pacman-conf) --gpgdir (keyring)
        --noconfirm --needed --assume-installed initramfs ...$args)
}

# Install packages into a fresh tree. With --dbs, from that directory of sync
# databases instead of downloading new ones: the tree gets exactly the
# versions those databases name, from the package cache, without the network.
export def bootstrap [tree: path, packages: list<string>, --dbs: path] {
    if ($tree | path exists) { ns-run - rm -rf $tree }
    mkdir ($tree | path join var lib pacman)
    let sync = if $dbs != null {
        ^cp -a $dbs ($tree | path join var lib pacman sync)
        "-S"
    } else { "-Sy" }

    step $"installing ($packages | length) packages into ($tree)"
    pacman-in $tree $sync ...$packages
}

# The package tree: what pacman installs for the layers, and nothing else. It
# persists between builds, and pacman only runs on it when the package set
# changes, so a change to a layer's usr/ never waits on pacman. Its sync
# databases move only with --update: that is the one way packages change
# version, and the only step that needs the network.
export def base [--update] {
    let dir = (base-dir)
    let stamp = (workspace | path join base.nuon)
    let dbs = ($dir | path join var lib pacman sync)
    let want = (layer-packages)
    let have = if ($stamp | path exists) and ($dbs | path exists) { open $stamp } else { null }
    let dropped = if $have == null { [] } else { $have | where { $in not-in $want } }
    let added = if $have == null { $want } else { $want | where { $in not-in $have } }

    if $have == null or ($dropped | is-not-empty) {
        # pacman could remove them, but a tree that has had packages removed
        # is not quite a tree that never had them. Start over, from the same
        # databases unless updating, so dropping one package upgrades nothing.
        rm -f $stamp
        if $have == null or $update {
            bootstrap $dir $want
        } else {
            let saved = (workspace | path join sync)
            rm -rf $saved
            ^cp -a $dbs $saved
            bootstrap $dir $want --dbs $saved
            rm -rf $saved
        }
    } else if $update {
        step "updating the package tree"
        pacman-in $dir -Syu ...$added
    } else if ($added | is-not-empty) {
        # Against the databases the rest of the tree came from, so adding a
        # package is never a partial upgrade.
        step $"adding ($added | str join ' ')"
        pacman-in $dir -S ...$added
    }
    $want | to nuon | save --force $stamp

    let synced = (ls ($dbs | path join core.db) | first | get modified | date humanize)
    print $"  ($want | length) packages, package databases dated ($synced)"
}

# Copy a layer's usr/ over the tree's /usr, as namespace root so every file
# ends up owned by root in the image. .keep files only hold empty directories
# in git.
export def apply-usr [src: path, tree: path] {
    if not ($src | path exists) { return }
    ns-run - sh -c $"tar -C '($src)' --exclude=.keep -cf - . | tar -C '($tree)/usr' -xpf -"
}

export def set-os-release [tree: path] {
    let c = (config)
    let file = ($tree | path join usr lib os-release)
    let kept = (open --raw $file | lines | where { |l| not ($l =~ '^(IMAGE_ID|IMAGE_VERSION)=') })
    $kept | append [$"IMAGE_ID=($c.id)" $"IMAGE_VERSION=($c.version)"] | str join "\n" | $in + "\n" | save --force $file
}

# Unit enablement lands in /etc/systemd as symlinks, and /etc does not ship.
# Move it under /usr/lib/systemd, where it takes effect from the image itself.
export def relocate-enablement [tree: path] {
    for scope in [system user] {
        let src = ($tree | path join etc systemd $scope)
        let dst = ($tree | path join usr lib systemd $scope)
        if not ($src | path exists) { continue }

        let entries = (ls -a $src | where { |e| ($e.name | str ends-with ".wants") or ($e.name | str ends-with ".requires") or $e.type == symlink })
        for e in $entries {
            let name = ($e.name | path basename)
            if ($e.name | str ends-with ".wants") or ($e.name | str ends-with ".requires") {
                ns-run - sh -c $"mkdir -p '($dst)/($name)' && cp -a '($e.name)/.' '($dst)/($name)/' && rm -rf '($e.name)'"
            } else {
                ns-run - sh -c $"rm -f '($dst)/($name)' && cp -a '($e.name)' '($dst)/($name)' && rm -f '($e.name)'"
            }
        }
    }
}

export def hermetic [tree: path] {
    step "making /usr hermetic"
    set-os-release $tree

    ^systemctl --root $tree preset-all out> /dev/null err> /dev/null
    relocate-enablement $tree

    # pacman's database describes what is in /usr, so it moves with /usr; a
    # tmpfiles rule links it back into /var at boot so `pacman -Q` works.
    let local = ($tree | path join var lib pacman local)
    if ($local | path exists) {
        ns-run - sh -c $"mkdir -p '($tree)/usr/lib/pacman' && rm -rf '($tree)/usr/lib/pacman/local' && mv '($local)' '($tree)/usr/lib/pacman/local'"
    }

    # /etc as the packages left it becomes the factory copy; tmpfiles merges it
    # into the real /etc at boot without overwriting anything already there.
    let factory = ($tree | path join usr share factory etc)
    ns-run - sh -c ($"rm -rf '($factory)' && mkdir -p '($factory)' && tar -C '($tree)/etc' "
        + "--exclude=./machine-id --exclude=./resolv.conf --exclude=./mtab --exclude=./os-release "
        + "--exclude=./.pwd.lock --exclude=./.updated "
        + $"-cf - . | tar -C '($factory)' -xpf -")

    # The verity signature is checked in userspace against these, in the
    # initrd and after switching root.
    let verity = ($tree | path join usr lib verity.d)
    mkdir $verity
    cp (keys-dir | path join db.crt) ($verity | path join $"((config).id).crt")

    # bootctl install picks the .signed copy when there is one, so a system
    # installed from this image (systemd-sysinstall) gets a boot loader that
    # passes Secure Boot. The image's own ESP is staged from it too.
    let boot = ($tree | path join usr lib systemd boot efi systemd-bootx64.efi)
    (^sbsign --key (keys-dir | path join db.key) --cert (keys-dir | path join db.crt)
        --output $"($boot).signed" $boot) e>| ignore
}

export def main [--update] {
    if not (keys-dir | path join db.key | path exists) {
        error make { msg: "no signing key yet - run `elv keys` first" }
    }

    base --update=$update

    # Every build starts from a pristine copy of the package tree, so nothing
    # a layer or the finalisation did last time can leak into this one. On
    # btrfs or xfs the copy shares extents with the original: about a second.
    let tree = (tree-dir)
    step "copying the package tree"
    ns-run - sh -c $"rm -rf '($tree)' && cp -a --reflink=auto '(base-dir)' '($tree)'"

    step "applying layers"
    apply-usr (project | path join lib usr) $tree
    for l in (layers) {
        print $"  (($l | path basename))"
        apply-usr ($l | path join usr) $tree
    }

    hermetic $tree
    print $"  kernel (kernel-version $tree)"
}
