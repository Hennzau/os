# The disk image: an ESP with signed systemd-boot and the UKI, then /usr as
# erofs with its dm-verity hash and a signature over the root hash - one
# systemd-repart run, which also emits each /usr partition as its own file for
# sysupdate to consume.

use common.nu *
use uki.nu [uki-path]

# Build-time partition layout. These are not shipped: the image carries its
# own runtime definitions (lib/usr/lib/repart.d) for the slots it grows into.
# %M and %A are IMAGE_ID and IMAGE_VERSION from the tree's os-release.
const REPART = {
    "00-esp.conf": "[Partition]
Type=esp
Format=vfat
CopyFiles=/.elv-esp:/
SizeMinBytes=512M
SizeMaxBytes=512M
SplitName=-
"
    "10-usr-verity-sig.conf": "[Partition]
Type=usr-verity-sig
Label=%M_%A_verity_sig
Verity=signature
VerityMatchKey=usr
SplitName=usr-verity-sig
"
    "11-usr-verity.conf": "[Partition]
Type=usr-verity
Label=%M_%A_verity
Verity=hash
VerityMatchKey=usr
SizeMinBytes=256M
SizeMaxBytes=256M
SplitName=usr-verity
"
    "12-usr.conf": "[Partition]
Type=usr
Label=%M_%A
CopyBlocks=/.elv-usr.erofs
Verity=data
VerityMatchKey=usr
SplitName=usr
"
}

# Staged in the workspace, then moved into the tree from inside the namespace:
# the tree's root directory is mode 0555, as the filesystem package ships it.
def stage-esp [tree: path] {
    let esp = (workspace | path join esp)
    if ($esp | path exists) { rm -r $esp }
    let efi = ($tree | path join usr lib systemd boot efi systemd-bootx64.efi.signed)

    for dir in [EFI/BOOT EFI/systemd EFI/Linux loader/keys/auto] { mkdir ($esp | path join $dir) }

    # The removable-media path is what firmware boots with no boot entries,
    # which is every fresh disk; the second copy is where bootctl expects it.
    for dst in [EFI/BOOT/BOOTX64.EFI EFI/systemd/systemd-bootx64.efi] { cp $efi ($esp | path join $dst) }
    cp (uki-path) ($esp | path join EFI Linux)

    # if-safe: enroll our keys automatically when running in a VM whose
    # firmware is in setup mode; on real hardware it stays a manual menu entry.
    "timeout 3\neditor no\nsecure-boot-enroll if-safe\n" | save --force ($esp | path join loader loader.conf)
    cp ...(glob (keys-dir | path join auto *.auth)) ($esp | path join loader keys auto)

    let target = ($tree | path join .elv-esp)
    ns-run - sh -c $"rm -rf '($target)' && cp -a '($esp)' '($target)'"
}

export def main [] {
    if not (uki-path | path exists) {
        error make { msg: "no UKI - run `elv uki` first" }
    }
    let tree = (tree-dir)
    let defs = (workspace | path join repart.d)
    let out = (out-dir | path join $"(image-name)_x86-64.raw")

    step "staging the ESP"
    stage-esp $tree

    rm -rf $defs
    mkdir $defs
    $REPART | transpose name body | each { |d| $d.body | save ($defs | path join $d.name) } | ignore

    # Old split files would otherwise be mistaken for this build's.
    glob (out-dir | path join $"(image-name)_x86-64*.raw") | each { rm $in } | ignore

    # erofs is built here rather than by repart (Format=erofs, CopyFiles=):
    # repart first copies the whole tree into a scratch directory and formats
    # that, which doubles the time of this stage. Inside the namespace, so
    # files owned by root in the tree are owned by root in the image. Paths in
    # the definitions are relative to --root, hence the file at the top of
    # the tree.
    step "building the /usr filesystem"
    ns-run - sh -c $"mkfs.erofs -zzstd '($tree)/.elv-usr.erofs' '($tree)/usr' > /dev/null"

    step "assembling the disk image"
    (ns-run - systemd-repart --empty=create --size=auto --dry-run=no --offline=yes
        --root $tree --definitions $defs
        --private-key (keys-dir | path join db.key)
        --certificate (keys-dir | path join db.crt)
        --split=yes --json=short $out) | save --force (workspace | path join repart.json)

    open (workspace | path join repart.json) | each { |p|
        let hash = if ($p.roothash? | default "" | is-empty) { "" } else { $"  roothash ($p.roothash | str substring 0..15)…" }
        print $"  ($p.label | fill -w 26) ($p.raw_size | into filesize | into string | fill -w 10 -a r)($hash)"
    } | ignore

    ns-run - rm -rf ($tree | path join .elv-esp) ($tree | path join .elv-usr.erofs)
    print ""
    ls (out-dir) | where name =~ (image-name) | each { |f| print $"  ($f.name | path basename)  ($f.size)" } | ignore
}

def built-image []: nothing -> path {
    let img = (out-dir | path join $"(image-name)_x86-64.raw")
    if not ($img | path exists) { error make { msg: "no image - run `elv build` first" } }
    $img
}

# What systemd imports into a test machine at boot, as credentials: a root
# password, autologin on the consoles, and answers for systemd-firstboot,
# which would otherwise prompt - /etc starts out empty. Keymap and timezone
# are this machine's, so the VM's keyboard types what its keys say. The signed
# image itself carries none of this.
def credentials []: nothing -> record {
    let keymap = (try { open /etc/vconsole.conf | lines | parse "KEYMAP={v}" | first | get v } catch { "us" })
    let timezone = (try { ^readlink /etc/localtime | str replace --regex '.*zoneinfo/' '' } catch { "UTC" })
    {
        "passwd.plaintext-password.root": "elv"
        "agetty.autologin": "root"
        "firstboot.locale": "C.UTF-8"
        "firstboot.keymap": $keymap
        "firstboot.timezone": $timezone
    }
}

# Boot the image in QEMU, in a window, with what the real machine has: UEFI,
# a TPM, a disk. The disk is a throwaway qcow2 overlay - the built image is
# never written to - larger than the image, so first-boot repart has room for
# the B slot, as it would on a real disk. The TPM and firmware variables are
# fresh on every run too. With --serial there is no window and the serial
# console is on stdio, for scripted checks; otherwise it goes to serial.log.
# --install adds a blank disk for the Installer entry to install onto; the
# installer registers it with the firmware, so the reboot lands on it.
export def vm [--secureboot, --serial, --install] {
    let img = (built-image)
    let ws = (workspace)

    let edk2 = "/usr/share/edk2/x64"
    let code = if $secureboot { $"($edk2)/OVMF_CODE.secboot.4m.fd" } else { $"($edk2)/OVMF_CODE.4m.fd" }
    let vars = ($ws | path join ovmf-vars.fd)
    cp $"($edk2)/OVMF_VARS.4m.fd" $vars

    let disk = ($ws | path join vm-overlay.qcow2)
    ^qemu-img create -q -f qcow2 -b $img -F raw $disk 64G
    # After the image's drive, so the image is always vda.
    let target = if $install {
        let t = ($ws | path join vm-target.qcow2)
        ^qemu-img create -q -f qcow2 $t 64G
        [-drive $"if=virtio,format=qcow2,file=($t)"]
    } else { [] }

    # --terminate: swtpm exits when QEMU closes the connection, so it never
    # outlives the VM. --daemon returns once the socket exists.
    let tpm = ($ws | path join tpm)
    rm -rf $tpm
    mkdir $tpm
    ^swtpm socket --tpm2 --tpmstate $"dir=($tpm)" --ctrl $"type=unixio,path=($tpm)/sock" --terminate --daemon

    # Quoted: in a nushell list, a comma separates items.
    let machine = if $secureboot {
        ["-machine" "q35,smm=on" "-global" "driver=cfi.pflash01,property=secure,value=on"]
    } else {
        ["-machine" "q35"]
    }

    # As mkosi does it: -nodefaults drops the emulated VGA that would sit
    # next to virtio-vga, and the serial port and CD drive with it. A virtio
    # tablet gives an absolute pointer, so the window never grabs the mouse.
    let serial_log = ($ws | path join serial.log)
    let console = if $serial {
        ["-nographic"]
    } else {
        print $"  serial console: ($serial_log)"
        ["-nodefaults" "-device" "virtio-vga" "-display" "sdl,gl=on" "-device" "virtio-tablet-pci"
            "-audio" "driver=pipewire,model=virtio" "-serial" $"file:($serial_log)"]
    }

    let smbios = (credentials | items { |k, v| [-smbios $"type=11,value=io.systemd.credential:($k)=($v)"] } | flatten)

    (^qemu-system-x86_64 ...$machine ...$console ...$smbios
        -enable-kvm -cpu host -smp 4 -m 4G
        -drive $"if=pflash,format=raw,readonly=on,file=($code)"
        -drive $"if=pflash,format=raw,file=($vars)"
        -drive $"if=virtio,format=qcow2,file=($disk)"
        ...$target
        -chardev $"socket,id=tpm,path=($tpm)/sock"
        -tpmdev emulator,id=tpm0,chardev=tpm -device tpm-tis,tpmdev=tpm0
        -device virtio-rng-pci
        -nic user,model=virtio-net-pci)
}

# Boot the image as a container, in this terminal, in seconds. Only /usr
# comes from the image: --volatile=yes puts it under a tmpfs root, as the real
# machine has, so this is /usr as it ships, minus firmware, bootloader and
# initrd. nspawn needs root to mount an image with no root partition -
# mountfsd refuses those to unprivileged users - hence run0.
export def boot [] {
    let img = (built-image)
    let creds = (credentials | items { |k, v| $"--set-credential=($k):($v)" })

    # usr=verity as well as signed: the host checks the signature against its
    # own trusted keys, and ours is not among them unless db.crt is installed
    # in /etc/verity.d. Without it, the hash tree is still verified.
    (^run0 systemd-nspawn --quiet
        --image $img
        --image-policy "root=absent:usr=signed+verity:esp=unprotected:=ignore"
        --volatile=yes
        --machine ((config).id)
        ...$creds
        --boot -- systemd.unit=multi-user.target)
}
