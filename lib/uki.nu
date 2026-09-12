# The UKI: kernel, initrd, command line and os-release in one PE binary,
# signed for Secure Boot. Kernel and stub come from the tree, not the host, so
# the image boots what it ships.
#
# It carries several profiles, each its own boot menu entry sharing the one
# kernel and initrd, and differing only in their command line.

use common.nu *
use initrd.nu

# /usr is found by partition type and label, and must carry a valid verity
# signature. / is found the same way: first boot's repart creates it in the
# initrd, with swap and /home (lib/usr/lib/repart.d) - root and swap LUKS2,
# unlocked by the TPM. A profile can put / elsewhere: the installer, on a
# tmpfs.
def cmdline [--root: string = "dissect"]: nothing -> list<string> {
    let id = (config).id
    [
        "mount.usr=dissect"
        $"root=($root)"
        "rw"
        # Arch builds the kernel with "archlinux" as its hostname, and PID 1
        # keeps a hostname that is already set when nothing configures one -
        # so os-release's DEFAULT_HOSTNAME never got a say. This replaces the
        # kernel's; /etc/hostname (hostnamectl) still wins over it.
        $"hostname=($id)"
        # The last console is /dev/console, where systemd writes: the screen.
        # The kernel log goes to both.
        "console=ttyS0,115200"
        "console=tty0"
        # Root and swap must be encrypted; /home need not be, homed encrypts
        # each home itself.
        "systemd.image_policy=esp=unprotected:xbootldr=unprotected+unused+absent:usr=signed:root=encrypted+absent:swap=encrypted+unused+absent:home=unprotected+absent:=ignore"
        # The policy alone does not hold at boot: when the kernel rejects the
        # signature, systemd-veritysetup retries without one, and a /usr with
        # a forged signature boots. This makes the kernel refuse any verity
        # device without a valid signature, checked against the firmware's db
        # - so the image needs Secure Boot, which was always what vouched
        # for everything else.
        "dm_verity.require_signatures=1"
        $"systemd.image_filter=usr=($id)_*:usr-verity=($id)_*:usr-verity-sig=($id)_*:root=($id)-*:swap=($id)-*:home=($id)-*"
    ]
}

# Profiles beyond the default one, profile 0, which is the UKI's own command
# line (see main).
#
# The installer is the same image booted into systemd-sysinstall, which
# copies this /usr and this UKI onto another disk (repart.sysinstall.d says
# how). The medium itself is left alone: no repart growing /usr or making a B
# slot on a USB stick, and so no root partition either: / is a tmpfs. A
# locked root password keeps firstboot from asking for one nobody will use,
# while it still asks locale, keymap and timezone - which sysinstall carries
# over to the installed system.
def profiles []: nothing -> list<record> {
    [
        {
            id: installer
            title: Installer
            root: tmpfs
            cmdline: [
                "rd.systemd.mask=systemd-repart.service"
                "systemd.mask=systemd-repart.service"
                "systemd.set-credential=passwd.hashed-password.root:!*"
                "systemd.unit=system-install.target"
            ]
        }
    ]
}

export def uki-path []: nothing -> path {
    out-dir | path join $"(image-name)_x86-64.efi"
}

export def main [] {
    let tree = (tree-dir)
    let initrds = (initrd paths)
    if not ($initrds | all { path exists }) {
        error make { msg: "no initrd - run `elv initrd` first" }
    }

    let kver = (kernel-version $tree)
    let efi = ($tree | path join usr lib systemd boot efi)
    let out = (uki-path)

    # Each profile is built on its own, as a small PE with just its
    # .profile and .cmdline sections, then joined into the real one.
    let joined = (profiles | each { |p|
        let file = (workspace | path join $"profile-($p.id).efi")
        let cmd = ((cmdline --root ($p.root? | default dissect)) | append $p.cmdline | str join " ")
        (^ukify build --profile $"ID=($p.id)\nTITLE=($p.title)" --cmdline $cmd
            --stub ($efi | path join addonx64.efi.stub) --output $file) e>| ignore
        [--join-profile $file]
    } | flatten)

    # amd-ucode installs its image into /boot, which the image discards; in
    # the UKI the stub hands it to the kernel, which applies it before the
    # first instruction of the OS runs.
    let microcode = (glob ($tree | path join boot "*-ucode.img") | each { [--microcode $in] } | flatten)

    step $"building the UKI for ($kver)"
    (^ukify build
        --linux ($tree | path join usr lib modules $kver vmlinuz)
        ...($initrds | each { [--initrd $in] } | flatten)
        --uname $kver
        --cmdline ((cmdline) | str join " ")
        --os-release $"@($tree | path join usr lib os-release)"
        ...$microcode
        --stub ($efi | path join linuxx64.efi.stub)
        # The first .profile section starts profile 0, the default entry;
        # everything before it is shared by all profiles.
        --profile "ID=main"
        ...$joined
        --signtool sbsign
        --secureboot-private-key (keys-dir | path join db.key)
        --secureboot-certificate (keys-dir | path join db.crt)
        # Signed expected PCR 11 values for every profile, and the key's
        # public half (.pcrpkey). The TPM releases the root and swap keys to
        # whatever that key signed rather than to one exact measurement, so
        # the next UKI - measured differently, signed alike - still unlocks.
        --pcr-private-key (keys-dir | path join db.key)
        --pcr-banks sha256
        --output $out)

    print $"  ($out) \((ls $out | get size | first))"
    print $"  profiles: main, (profiles | get title | str join ', ')"
}
