# `elv layer`: try a usr.d layer's files on the running system, with no build
# and nothing left behind.
#
# systemd-sysext overlays /usr with every tree it finds in /run/extensions,
# and /run is empty again after a reboot: a merged layer lasts exactly as long
# as this boot, and the signed image on disk is never touched. Only /usr is
# merged - that is all sysext does, and all a layer ships anyway.

use common.nu *
use tree.nu

# Extensions are built here first: the tree is made as us, then copied into
# /run as root.
def stage-dir []: nothing -> path { workspace | path join sysext }

# Which layer a name means: its directory name, or the one layer whose name
# contains it - `elv layer dev` for usr.d/95-dev.
def find-layer [name: string] {
    let all = (layers)
    let named = ($all | where { |l| ($l | path basename) == $name })
    let hit = (if ($named | is-empty) { $all | where { |l| ($l | path basename) =~ $name } } else { $named })
    if ($hit | length) == 1 { return ($hit | first) }
    let have = ($all | each { |l| $l | path basename } | str join ", ")
    if ($hit | is-empty) {
        error make { msg: $"no layer matches '($name)' - there is: ($have)" }
    }
    let matched = ($hit | each { |l| $l | path basename } | str join ", ")
    error make { msg: $"'($name)' matches several layers: ($matched)" }
}

# What a sysext cannot carry. None of it is fatal - the files still merge -
# but it is why a layer can behave differently here than in an image.
def caveats [layer: path, stage: path] {
    let name = ($layer | path basename)
    let packages = ($layer | path join packages)
    if ($packages | path exists) {
        let n = (open --raw $packages | lines | where { |l| ($l | str trim) != "" and not ($l | str starts-with "#") } | length)
        print $"    ($n) packages are not installed by this - only files are merged"
    }
    if ($layer | path join modules | path exists) {
        print "    kernel modules are not built into an extension (elv modules does that)"
    }
    if (($stage | path join usr lib tmpfiles.d | path exists)
        or ($stage | path join usr share user-tmpfiles.d | path exists)) {
        print "    /etc and ~/.config entries are not created: they would outlive the merge"
    }
}

# One layer as a directory systemd-sysext will take: its usr/ tree, templates
# rendered in as a build renders them, plus the extension-release file that
# lets systemd match the extension to this OS.
def stage [layer: path]: nothing -> path {
    let name = ($layer | path basename)
    let src = ($layer | path join usr)
    if not ($src | path exists) {
        error make { msg: $"($name) ships no usr/ tree - there is nothing to merge" }
    }
    step $"staging ($name)"
    let stage = (stage-dir | path join $name)
    rm -rf $stage
    mkdir ($stage | path join usr)
    tree apply-usr $src $stage

    let c = (config)
    # ID=_any, because the host's os-release is Arch's: it has BUILD_ID=rolling
    # and no VERSION_ID, and any other ID would make systemd insist on matching
    # a version that is not there. The name of this file must be the name of
    # the directory in /run/extensions.
    let release = ([
        "# Written by elv layer - systemd-sysext(8)."
        "ID=_any"
        "ARCHITECTURE=x86-64"
        $"IMAGE_ID=($c.id)"
        $"IMAGE_VERSION=($c.version)"
        $"SYSEXT_SCOPE=system"
    ] | append (
        # systemd reloads the manager itself after merging, so a unit the
        # layer adds is known without a daemon-reload by hand.
        if ($stage | path join usr lib systemd system | path exists) {
            ["EXTENSION_RELOAD_MANAGER=1"]
        } else { [] }
    ) | str join "\n")
    let dir = ($stage | path join usr lib extension-release.d)
    mkdir $dir
    $"($release)\n" | save --force --raw ($dir | path join $"extension-release.($name)")
    caveats $layer $stage
    $stage
}

# What is merged now, and what is staged for it. No root needed for either.
export def status [] {
    ^systemd-sysext status
    if ("/run/extensions" | path exists) {
        let staged = (ls /run/extensions | get name | path basename)
        if ($staged | is-not-empty) {
            print $"staged in /run/extensions: ($staged | str join ', ')"
        }
    }
}

# Merge the named layers into the running /usr; with no name, say what is
# merged already. --off unmerges everything and clears /run/extensions, which
# a reboot does by itself.
export def main [
    ...names: string    # layers to merge: a layer's name, or part of one
    --off               # unmerge everything instead
] {
    if $off {
        step "unmerging"
        ^run0 sh -c "systemd-sysext unmerge; rm -rf /run/extensions"
        rm -rf (stage-dir)
        return
    }
    if ($names | is-empty) { return (status) }

    let staged = ($names | each { |n| stage (find-layer $n) })
    # One privileged step for all of them: copy in as root, then refresh once.
    # --always-refresh, or an edit to a layer that is merged already changes
    # nothing - systemd skips the work when the set of extensions is the same.
    let copy = ($staged | each { |s|
        let name = ($s | path basename)
        $"rm -rf /run/extensions/($name); cp -a '($s)' /run/extensions/($name); chown -R root:root /run/extensions/($name)"
    } | str join "; ")
    step $"merging ($staged | each { |s| $s | path basename } | str join ', ')"
    ^run0 sh -c ("install -d -m 0755 /run/extensions; " + $copy
        + "; systemd-sysext --always-refresh=yes refresh")
    status
    print "Gone at the next reboot, or now with: elv layer --off"
}
