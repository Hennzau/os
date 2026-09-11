# The UKI: kernel, initrd, command line and os-release in one PE binary,
# signed for Secure Boot. Kernel and stub come from the tree, not the host, so
# the image boots what it ships.
#
# It carries several profiles, each its own boot menu entry sharing the one
# kernel and initrd, and differing only in their command line.

use common.nu *
use initrd.nu

# /usr is found by partition type and label, and must carry a valid verity
# signature; / is a tmpfs for now, so nothing but /usr persists.
def cmdline []: nothing -> list<string> {
    let id = (config).id
    [
        "mount.usr=dissect"
        "root=tmpfs"
        "rw"
        # The last console is /dev/console, where systemd writes: the screen.
        # The kernel log goes to both.
        "console=ttyS0,115200"
        "console=tty0"
        "systemd.image_policy=esp=unprotected:xbootldr=unprotected+unused+absent:usr=signed:=ignore"
        $"systemd.image_filter=usr=($id)_*:usr-verity=($id)_*:usr-verity-sig=($id)_*"
    ]
}

# Profiles beyond the default one, profile 0, which is the UKI's own command
# line (see main).
#
# The installer is the same image booted into systemd-sysinstall, which
# copies this /usr and this UKI onto another disk (repart.sysinstall.d says
# how). The medium itself is left alone: no repart growing /usr or making a B
# slot on a USB stick. A locked root password keeps firstboot from asking for
# one nobody will use, while it still asks locale, keymap and timezone -
# which sysinstall carries over to the installed system.
def profiles []: nothing -> list<record> {
    [
        {
            id: installer
            title: Installer
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
        let cmd = ((cmdline) | append $p.cmdline | str join " ")
        (^ukify build --profile $"ID=($p.id)\nTITLE=($p.title)" --cmdline $cmd
            --stub ($efi | path join addonx64.efi.stub) --output $file) e>| ignore
        [--join-profile $file]
    } | flatten)

    step $"building the UKI for ($kver)"
    (^ukify build
        --linux ($tree | path join usr lib modules $kver vmlinuz)
        ...($initrds | each { [--initrd $in] } | flatten)
        --uname $kver
        --cmdline ((cmdline) | str join " ")
        --os-release $"@($tree | path join usr lib os-release)"
        --stub ($efi | path join linuxx64.efi.stub)
        # The first .profile section starts profile 0, the default entry;
        # everything before it is shared by all profiles.
        --profile "ID=main"
        ...$joined
        --signtool sbsign
        --secureboot-private-key (keys-dir | path join db.key)
        --secureboot-certificate (keys-dir | path join db.crt)
        --output $out)

    print $"  ($out) \((ls $out | get size | first))"
    print $"  profiles: main, (profiles | get title | str join ', ')"
}
