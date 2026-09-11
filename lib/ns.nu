# Runs inside the build user namespace (see `ns-run` in common.nu).
#
# We are "root" here only in name: uid 0 is you, 1..65536 are your subuids. That
# is enough for pacman to chown files to arbitrary users and chroot for its
# scriptlets, without ever being root on the host.
#
# With a tree argument, the API filesystems pacman's scriptlets expect are set
# up inside it first - the same set pacstrap -N mounts. They exist only in this
# mount namespace and vanish with it, so nothing stale is ever left in the tree.

def dev-node [tree: path, name: string] {
    let target = ($tree | path join dev $name)
    touch $target
    ^mount --bind $"/dev/($name)" $target
}

def --wrapped main [tree: string, ...cmd: string] {
    if $tree != "-" {
        for d in [proc sys dev run tmp] { mkdir ($tree | path join $d) }

        ^mount --bind $tree $tree
        ^mount -t proc proc ($tree | path join proc) -o nosuid,noexec,nodev
        ^mount --rbind /sys ($tree | path join sys)
        ^mount -t tmpfs tmpfs ($tree | path join dev) -o mode=0755,nosuid
        for n in ["null" "zero" "full" "random" "urandom" "tty"] { dev-node $tree $n }
        ^ln -s /proc/self/fd ($tree | path join dev fd)
        ^ln -s /proc/self/fd/0 ($tree | path join dev stdin)
        ^ln -s /proc/self/fd/1 ($tree | path join dev stdout)
        ^ln -s /proc/self/fd/2 ($tree | path join dev stderr)
        mkdir ($tree | path join dev shm)
        ^mount -t tmpfs tmpfs ($tree | path join run) -o mode=0755,nosuid,nodev
        ^mount -t tmpfs tmpfs ($tree | path join tmp) -o mode=1777,nosuid,nodev
    }

    run-external ($cmd | first) ...($cmd | skip 1)
}
