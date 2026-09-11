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

# Boot the last built image in a QEMU window; --serial for a terminal instead,
# --install for a blank second disk to try the Installer entry on.
def "main vm" [--secureboot, --serial, --install] {
    image vm --secureboot=$secureboot --serial=$serial --install=$install
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
