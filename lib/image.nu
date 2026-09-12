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

    # manual: firmware in setup mode gets an "Enroll Secure Boot keys" menu
    # entry, nothing more - taking over a machine's Secure Boot is a choice
    # made at the machine. (`elv vm` hands its VM the keys already enrolled.)
    # No timeout: the menu stays hidden unless a key is held at boot, as on
    # elvOS and on a system bootctl installs - a visible countdown costs every
    # boot three seconds, test VMs included.
    # console-mode keep: the firmware's own text mode, as elvOS had it.
    "editor no\nconsole-mode keep\nsecure-boot-enroll manual\n" | save --force ($esp | path join loader loader.conf)
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

# What systemd imports into a scripted test machine at boot, as credentials:
# a root password, autologin on the consoles, and answers for what
# systemd-firstboot would otherwise ask on every boot - /etc starts out empty.
# Keymap and timezone are this machine's, so the VM's keyboard types what its
# keys say; the locale is the image's own. The signed image carries none of
# this, and a VM in a window gets none of it either: it boots as a real
# machine does, through every first-boot question.
def credentials []: nothing -> record {
    let keymap = (try { open /etc/vconsole.conf | lines | parse "KEYMAP={v}" | first | get v } catch { "us" })
    let timezone = (try { ^readlink /etc/localtime | str replace --regex '.*zoneinfo/' '' } catch { "UTC" })
    {
        "passwd.plaintext-password.root": "elv"
        "agetty.autologin": "root"
        "firstboot.keymap": $keymap
        "firstboot.timezone": $timezone
        # homed's first-user question has no answer to pre-set short of
        # creating a user; a drop-in, delivered as a credential, skips it.
        "systemd.unit-dropin.systemd-homed-firstboot.service": "[Unit]\nConditionPathExists=/run/elv-vm-wants-a-user\n"
        # vmctl's console (hvc0) gets a bare root bash instead of a login:
        # the login shell is nushell, whose line editor asks the terminal
        # for the cursor position and waits for an answer no socket gives.
        "systemd.unit-dropin.serial-getty@hvc0.service": "[Service]\nExecStart=\nExecStart=/usr/bin/bash -c 'echo elv-vmctl-ready; exec bash --noediting --noprofile --norc'\n"
    }
}

# As SMBIOS strings: a value with a newline cannot be one, so those go
# base64-encoded, as systemd's .binary form of the credential.
def smbios-credentials []: nothing -> list<string> {
    credentials | items { |k, v|
        let value = if ($v | str contains "\n") {
            $"io.systemd.credential.binary:($k)=($v | encode base64)"
        } else {
            $"io.systemd.credential:($k)=($v)"
        }
        [-smbios $"type=11,value=($value)"]
    } | flatten
}

# The scale of the output the VM window opens on - niri's focused output;
# 1 under anything else.
def host-scale []: nothing -> float {
    if (which niri | is-empty) { return 1.0 }
    let out = (^niri msg --json focused-output | complete)
    if $out.exit_code != 0 { return 1.0 }
    $out.stdout | from json | get -o logical.scale | default 1.0 | into float
}

# Firmware variables with our certificate as PK, KEK and db, and Secure Boot
# on: what the boot menu's enroll entry leaves a machine with. The image only
# enrolls by hand (loader.conf), and a VM's variables are new every run.
# virt-fw-vars runs from the built tree (virt-firmware is in 00-base): the
# host need not have it.
def enrolled-vars [out: path] {
    let tree = (tree-dir)
    let stage = ($tree | path join run elv-vars)
    let owner = (random uuid)
    let crt = "/run/elv-vars/db.crt"
    ns-run - sh -c ($"mkdir -p '($stage)' && cp '(keys-dir | path join db.crt)' '($stage)/' && "
        + $"chroot '($tree)' virt-fw-vars --loglevel warning -i /usr/share/edk2/x64/OVMF_VARS.4m.fd -o /run/elv-vars/vars.fd "
        + $"--set-pk ($owner) ($crt) --add-kek ($owner) ($crt) --add-db ($owner) ($crt) --sb && "
        + $"cp '($stage)/vars.fd' '($out)' && rm -rf '($stage)'")
}

# Boot the image in QEMU, in a window, with what the real machine has: UEFI
# with Secure Boot, a TPM, a disk. The disk is a throwaway qcow2 overlay - the
# built image is never written to - larger than the image, so first-boot
# repart has room for the B slot, as it would on a real disk. The TPM and firmware variables are
# fresh on every run too.
#
# With --serial there is no window and the serial console is on stdio.
# Otherwise the serial console and QEMU's monitor are sockets in the
# workspace, which `elv vmctl` drives, and the serial output is logged to
# serial.log; --headless keeps the display but shows no window, for scripted
# runs that still want screenshots. --install adds a blank disk for the
# Installer entry to install onto; the installer registers it with the
# firmware, so the reboot lands on it. --pristine drops the test
# credentials from --headless or --serial as well. --share offers a host
# directory to the guest, read-only, to build the image from inside itself:
# `mount -t 9p -o trans=virtio,ro elv /mnt` in there. The firmware comes with
# our keys enrolled; --setup-mode starts it with none, as a new machine, and
# shows the boot menu, whose "Enroll Secure Boot keys" entry takes them.
export def vm [--serial, --headless, --install, --pristine, --setup-mode, --share: path] {
    let img = (built-image)
    let ws = (workspace)
    # First thing: a vmctl started alongside must not read the last run's.
    rm -f ...([serial.log console.log vmctl.state serial.sock console.sock qmp.sock] | each { |f| $ws | path join $f })

    let edk2 = "/usr/share/edk2/x64"
    # Always Secure Boot: /usr only activates with a signature the kernel
    # can check, against the firmware's db.
    let code = $"($edk2)/OVMF_CODE.secboot.4m.fd"
    let vars = ($ws | path join ovmf-vars.fd)
    if $setup_mode { cp $"($edk2)/OVMF_VARS.4m.fd" $vars } else { enrolled-vars $vars }

    let disk = ($ws | path join vm-overlay.qcow2)
    ^qemu-img create -q -f qcow2 -b $img -F raw $disk 64G
    # After the image's drive, so the image is always vda.
    let target = if $install {
        let t = ($ws | path join vm-target.qcow2)
        ^qemu-img create -q -f qcow2 $t 64G
        [-drive $"if=virtio,format=qcow2,file=($t)"]
    } else { [] }

    let shared = if $share != null {
        [-virtfs $"local,path=($share | path expand),mount_tag=elv,security_model=none,readonly=on"]
    } else { [] }

    # --terminate: swtpm exits when QEMU closes the connection, so it never
    # outlives the VM. --daemon returns once the socket exists.
    let tpm = ($ws | path join tpm)
    rm -rf $tpm
    mkdir $tpm
    ^swtpm socket --tpm2 --tpmstate $"dir=($tpm)" --ctrl $"type=unixio,path=($tpm)/sock" --terminate --daemon

    # Quoted: in a nushell list, a comma separates items.
    let machine = ["-machine" "q35,smm=on" "-global" "driver=cfi.pflash01,property=secure,value=on"]

    # As mkosi does it: -nodefaults drops the emulated VGA that would sit
    # next to virtio-vga, and the serial port and CD drive with it.
    #
    # The window is GTK's, not SDL's, for grab-on-hover: with the pointer over
    # it, QEMU grabs the keyboard, and GTK's grab on Wayland inhibits the
    # compositor's shortcuts - Super-anything reaches the guest, no click
    # needed. SDL grabs only on a click in a relative-pointer window, or on
    # Ctrl-Alt-G. With the grab tied to hovering, the pointer can be absolute
    # (the tablet): it moves in and out of the window freely. Ctrl-Alt-M
    # shows the menu bar.
    let console = if $serial {
        ["-nographic"]
    } else {
        # Two consoles. The serial port carries firmware, boot menu and kernel
        # log, to serial.log. The virtio console (hvc0) is for vmctl: systemd
        # puts an autologin getty on it by itself, no kernel output mixes in,
        # and unlike an emulated UART it has flow control - bytes typed fast
        # into a 16550 sometimes arrive twice. Its log sees everything the
        # guest writes, whether or not a client is on the socket.
        let display = if $headless { [-display none] } else {
            # One guest pixel per screen pixel: QEMU sizes the guest to the
            # window in logical pixels divided by `scale`, so 1/(the output's
            # scale) makes a full-screen window the panel's own resolution
            # (2880x1800 at niri's 1.75) - and the guest's text as large as
            # on the machine itself. Zoom-to-fit would ignore `scale`.
            # QEMU's own fullscreen (Ctrl-Alt-F) ignores it too; niri's
            # does not.
            [-display $"gtk,gl=on,grab-on-hover=on,show-tabs=off,show-menubar=off,zoom-to-fit=off,scale=(1 / (host-scale) | math round --precision 4)"
                -device virtio-tablet-pci -audio "driver=pipewire,model=virtio"]
        }
        ["-nodefaults" "-device" "virtio-vga" ...$display
            "-serial" $"file:($ws)/serial.log"
            "-device" "virtio-serial-pci"
            "-chardev" $"socket,id=console,path=($ws)/console.sock,server=on,wait=off,logfile=($ws)/console.log"
            "-device" "virtconsole,chardev=console"
            # The guest agent's channel, on the same virtio-serial bus.
            "-chardev" $"socket,id=qga,path=($ws)/qga.sock,server=on,wait=off"
            "-device" "virtserialport,chardev=qga,name=org.qemu.guest_agent.0"
            "-qmp" $"unix:($ws)/qmp.sock,server=on,wait=off"]
    }

    # Only where no one could answer firstboot: a headless run has no screen,
    # and on --serial the questions go to tty0, which the terminal is not.
    let scripted = ($headless or $serial) and not $pristine
    let smbios = if $scripted { smbios-credentials } else { [] }
    # The image's boot menu stays hidden unless a key is held, which is hard
    # to time in a VM: when a person drives it, systemd-boot is told to show
    # it for three seconds. Scripted runs pick entries with bootctl - except
    # in setup mode, where the enroll entry is only in the menu.
    let menu = if $scripted and not $setup_mode { [] } else { [-smbios "type=11,value=io.systemd.boot.timeout=3"] }

    (^qemu-system-x86_64 ...$machine ...$console ...$smbios ...$menu
        -enable-kvm -cpu host -smp 4 -m 4G
        -drive $"if=pflash,format=raw,readonly=on,file=($code)"
        -drive $"if=pflash,format=raw,file=($vars)"
        -drive $"if=virtio,format=qcow2,file=($disk)"
        ...$target
        ...$shared
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
    # nspawn unescapes the value C-style, so newlines travel as \n.
    let creds = (credentials | items { |k, v| $"--set-credential=($k):($v | str replace --all "\n" '\n')" })

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
