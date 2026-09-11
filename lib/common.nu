# Paths, configuration and the namespace runner every stage shares.

# The project root: the directory holding the `elv` entry point.
export def project []: nothing -> path {
    $env.ELV_ROOT
}

export def config []: nothing -> record {
    open (project | path join image.nuon)
}

# Where the trees are built. It must not be under $HOME: a systemd-homed home
# is an idmapped mount that can only hold files owned by its user, and a root
# filesystem is full of files owned by other UIDs. /var/tmp is a plain
# filesystem and survives reboots, so the package cache and trees persist.
export def workspace []: nothing -> path {
    let ws = ("/var/tmp/elv.os" | path join (config).id)
    mkdir $ws
    $ws
}

export def base-dir []: nothing -> path { workspace | path join base }
export def tree-dir []: nothing -> path { workspace | path join tree }
export def initrd-dir []: nothing -> path { workspace | path join initrd }

export def keys-dir []: nothing -> path { project | path join keys }

export def out-dir []: nothing -> path {
    let out = (project | path join out)
    mkdir $out
    $out
}

# Downloaded packages. Lives in $HOME's cache because packages are plain files
# owned by us - only the extracted trees need a non-idmapped filesystem.
export def cache-dir []: nothing -> path {
    let dir = ($env.XDG_CACHE_HOME? | default ($env.HOME | path join .cache) | path join elv.os pkg)
    mkdir $dir
    $dir
}

# Run a command as "root" in a user namespace: uid 0 is you, 1..65536 are your
# subuids. With a tree, pacman-style API filesystems are mounted inside it for
# the duration (see ns.nu); with "-", nothing is mounted.
export def --wrapped ns-run [tree: string, ...cmd: string] {
    (^unshare --map-auto --map-root-user --fork --pid --mount --propagation private
        -- nu (project | path join lib ns.nu) $tree ...$cmd)
}

export def step [msg: string] {
    print $"(ansi green_bold)==>(ansi reset) ($msg)"
}

export def image-name []: nothing -> string {
    let c = (config)
    $"($c.id)_($c.version)"
}

# Layers in application order.
export def layers []: nothing -> list<path> {
    let dir = (project | path join usr.d)
    if not ($dir | path exists) { return [] }
    ls $dir | where type == dir | get name | sort
}

# The kernel version installed in a tree. Arch keeps exactly one.
export def kernel-version [tree: path]: nothing -> string {
    let kvers = (ls ($tree | path join usr lib modules) | where type == dir | get name | path basename)
    if ($kvers | length) != 1 {
        error make { msg: $"expected one kernel in ($tree), found: ($kvers | str join ', ')" }
    }
    $kvers | first
}
