#!/usr/bin/env nu
# elv - build Arch images with a hermetic, verity-signed /usr.
#
# The image is fixed in shape - ESP with a signed UKI, erofs /usr with dm-verity
# and a signed root hash, sysupdate transfers built in. What goes into /usr is
# yours: the layers in usr.d/, each a package list plus a usr/ tree.

use lib/common.nu *
use lib/keys.nu
use lib/tree.nu
use lib/modules.nu
use lib/initrd.nu
use lib/uki.nu
use lib/image.nu
use lib/burn.nu

$env.ELV_ROOT = $env.FILE_PWD

def main [] {
    help main
}

# Generate the signing key, certificate and Secure Boot enrollment files.
def "main keys" [
    --force         # replace existing keys (moved aside, not deleted)
    --key: path     # import this private key instead of generating one...
    --cert: path    # ...with its certificate (e.g. elvOS's mkosi.key/.crt)
] {
    keys --force=$force --key=$key --cert=$cert
}

# Build everything: tree, initrd, UKI, disk image. pacman only runs when the
# layers' package lists change; --update syncs and upgrades every package.
def "main build" [--update, --installer] {
    tree --update=$update
    modules
    initrd
    uki
    image --installer=$installer
}

# Copy the package tree and apply the usr.d layers, kernel modules built from
# source included; --update upgrades packages.
def "main tree" [--update] {
    tree --update=$update
    modules
}

# Build the layers' kernel modules (usr.d/*/modules/NAME) into the tree.
def "main modules" [] { modules }

# Render every layer template next to itself (gitignored), as a build renders
# them into the image: what editors and language servers need to see, above
# all Quickshell's theme/Theme.qml.
def "main render" [] { tree render-all }

# Build the initrd from its own small tree.
def "main initrd" [] { initrd }

# Build and sign the UKI.
def "main uki" [] { uki }

# Assemble the ESP and /usr partitions into a disk image. --installer makes
# a second image, <id>_<version>_installer_x86-64.raw, whose only difference
# is that it boots the Installer entry rather than showing a menu - what a
# USB stick to install from wants (`elv burn --installer`).
def "main image" [--installer] { image --installer=$installer }

# Boot the last built image in a QEMU window, as a fresh machine would: every
# first-boot question. --serial for a terminal, --headless for no window
# (drive it with vmctl) - both pre-answered, with root autologin, unless
# --pristine. --install adds a blank disk to try the Installer entry on,
# --share DIR offers a host directory to the guest, read-only. The firmware
# has our keys enrolled; --setup-mode leaves it blank, for the boot menu's
# enroll entry. --gpu gives a headless run a 3D GPU, as the window has, for
# testing the desktop (vmctl screen cannot read it then).
def "main vm" [--serial, --headless, --install, --pristine, --setup-mode, --gpu, --share: path] {
    image vm --serial=$serial --headless=$headless --install=$install --pristine=$pristine --setup-mode=$setup_mode --gpu=$gpu --share=$share
}

# Write the last built image to a disk, e.g. a USB stick (via run0), or to a
# file. --installer writes the installer medium instead (see `elv image`).
def "main burn" [target: path, --yes, --installer] {
    burn $target --yes=$yes --installer=$installer
}

# Update the running system to the last built image, as systemd-sysupdate
# would from a server: /usr into the other slot, the UKI beside the current
# one. It boots next time; --reboot to go there now. The image must carry a
# newer version than the running one (image.nuon).
def "main sysupdate" [--reboot] {
    let args = if $reboot { [--reboot] } else { [] }
    ^run0 systemd-sysupdate --transfer-source (out-dir) update ...$args
}

# Drive a running `elv vm`: wait, run, reboot, key, screen, log, quit.
def --wrapped "main vmctl" [...args] {
    with-env { ELV_WORKSPACE: (workspace) } { ^python3 (project | path join lib vmctl.py) ...$args }
}

# Boot the last built image's /usr in a container, in this terminal.
def "main boot" [] { image boot }

# Remove the workspace (package tree, build tree, initrd); keeps keys, outputs
# and the package cache.
def "main clean" [] {
    let ws = (workspace)
    step $"removing ($ws)"
    ns-run - rm -rf $ws
}
