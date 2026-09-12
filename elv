#!/usr/bin/env nu
# elv - build Arch images with a hermetic, verity-signed /usr.
#
# The image is fixed in shape - ESP with a signed UKI, erofs /usr with dm-verity
# and a signed root hash, sysupdate transfers built in. What goes into /usr is
# yours: the layers in usr.d/, each a package list plus a usr/ tree.

use lib/common.nu *
use lib/keys.nu
use lib/tree.nu
use lib/initrd.nu
use lib/uki.nu
use lib/image.nu
use lib/burn.nu

$env.ELV_ROOT = $env.FILE_PWD

def main [] {
    help main
}

# Generate the signing key, certificate and Secure Boot enrollment files.
def "main keys" [--force] {
    keys --force=$force
}

# Build everything: tree, initrd, UKI, disk image. pacman only runs when the
# layers' package lists change; --update syncs and upgrades every package.
def "main build" [--update] {
    tree --update=$update
    initrd
    uki
    image
}

# Copy the package tree and apply the usr.d layers; --update upgrades packages.
def "main tree" [--update] { tree --update=$update }

# Build the initrd from its own small tree.
def "main initrd" [] { initrd }

# Build and sign the UKI.
def "main uki" [] { uki }

# Assemble the ESP and /usr partitions into a disk image.
def "main image" [] { image }

# Boot the last built image in a QEMU window, as a fresh machine would: every
# first-boot question. --serial for a terminal, --headless for no window
# (drive it with vmctl) - both pre-answered, with root autologin, unless
# --pristine. --install adds a blank disk to try the Installer entry on,
# --share DIR offers a host directory to the guest, read-only. The firmware
# has our keys enrolled; --setup-mode leaves it blank, for the boot menu's
# enroll entry.
def "main vm" [--serial, --headless, --install, --pristine, --setup-mode, --share: path] {
    image vm --serial=$serial --headless=$headless --install=$install --pristine=$pristine --setup-mode=$setup_mode --share=$share
}

# Write the last built image to a disk, e.g. a USB stick (via run0), or to a file.
def "main burn" [target: path, --yes] { burn $target --yes=$yes }

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
