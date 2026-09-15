# Kernel modules built from source: a layer's modules/NAME/ is a directory
# kbuild builds as an external module - a Kbuild file and the sources. They
# are compiled against the image's own kernel in a tree of their own, with
# gcc and that kernel's headers installed from the package tree's databases
# (so headers and kernel are the same build), and neither ends up in /usr.
# The results go to /usr/lib/modules/KVER/updates, which Arch's depmod.d
# (`search updates extramodules built-in`) ranks above the kernel's own
# directory: a module named like an in-tree one replaces it.

use common.nu *
use tree.nu [bootstrap]

# What kbuild runs besides gcc (binutils comes with it) and make; the
# headers package brings pahole (BTF) and zstd.
const TOOLS = [bash coreutils findutils gawk grep sed diffutils gcc make]

def sources []: nothing -> list<path> {
    layers | each { |l| glob ($l | path join "modules/*/Kbuild") } | flatten | each { path dirname } | sort
}

def build-dir []: nothing -> path { workspace | path join modules-build }

# The compiler tree, made again only when the kernel, the package databases
# or this file change.
def toolchain [base: path, kver: string]: nothing -> string {
    let dir = (build-dir)
    let dbs = ($base | path join var lib pacman sync)
    let headers = $"(open --raw ($base | path join usr lib modules $kver pkgbase) | str trim)-headers"
    let key = {
        kernel: $kver
        databases: (glob ($dbs | path join *.db) | sort | each { open --raw | hash sha256 })
        recipe: (open --raw (project | path join lib modules.nu) | hash sha256)
    } | to nuon
    let stamp = (workspace | path join modules-build.key)
    if ($dir | path exists) and ($stamp | path exists) and (open --raw $stamp) == $key { return $key }
    rm -f $stamp

    bootstrap $dir ($TOOLS | append $headers) --dbs $dbs
    if not ($dir | path join usr lib modules $kver build Makefile | path exists) {
        error make { msg: $"($headers) has no headers for ($kver)" }
    }
    $key | save --force $stamp
    $key
}

# Build one module into out/, stripped and compressed as Arch ships its own.
# Arch's kernel has no CONFIG_MODVERSIONS: nothing checks at load time that a
# replaced module's functions still match their callers' (btusb calls into
# btrtl), so a module whose source belongs to one kernel version must refuse
# to build for another - its Kbuild can compare $(VERSION).$(PATCHLEVEL).
def compile [src: path, dir: path, kver: string, out: path] {
    ns-run - sh -c $"rm -rf '($dir)/src' && mkdir '($dir)/src' && cp -r '($src)/.' '($dir)/src/'"
    (ns-run $dir chroot $dir sh -c
        ($"make -s -C /usr/lib/modules/($kver)/build M=/src modules && cd /src && "
        + 'for m in *.ko; do strip --strip-debug "$m" && zstd -q -19 --rm "$m"; done'))
    rm -rf $out
    mkdir $out
    for ko in (glob ($dir | path join src "*.ko.zst")) { cp $ko $out }
    compile-commands $src $dir $out
}

# What clangd needs to read the module's source as the kernel builds it -
# hundreds of include paths and -D's, which no editor guesses. kbuild leaves
# the exact command in `.<obj>.o.cmd`; it was run chrooted in the toolchain
# tree, so every absolute path gets that tree in front of it. Written to the
# module's cache and copied next to the source (gitignored) by main, so a
# warm build keeps it in place too.
def compile-commands [src: path, dir: path, out: path] {
    let entries = (glob ($dir | path join src ".*.o.cmd") | where { $in !~ '\.mod\.o\.cmd$' } | each { |f|
        let name = ($f | path basename | str replace --regex '^\.(.*)\.o\.cmd$' '$1')
        let source = ($src | path join $"($name).c")
        if not ($source | path exists) { return null }
        # Up to the first ';': kbuild records objtool's run after the
        # compiler's on the same line, and clangd would read its arguments.
        let cmd = (open --raw $f | lines | first
            | str replace --regex '^[^:]*:=\s*' ''
            | split row ";" | first
            | str replace --all " /usr/" $" ($dir)/usr/"
            | str replace --all "-I/usr/" $"-I($dir)/usr/")
        { directory: ($dir | path join src), file: $source, command: $cmd }
    } | compact)
    if ($entries | is-not-empty) {
        $entries | to json | save --force ($out | path join compile_commands.json)
    }
}

# Firmware the module asks for beyond what the kernel's module of the same
# name does (that list is linux-firmware's business), missing from the image.
def missing-firmware [tree: path, kver: string, name: string, ko: path]: nothing -> list<string> {
    let asks = { |f| ^modinfo -F firmware $f | lines }
    let stock = (glob ($tree | path join usr lib modules $kver kernel $"**/($name).ko*") | each { do $asks $in } | flatten)
    let fw = ($tree | path join usr lib firmware)
    do $asks $ko | where { $in not-in $stock } | where { |f|
        not ([$f $"($f).zst" $"($f).xz"] | any { |c| $fw | path join $c | path exists })
    }
}

export def main [] {
    let srcs = (sources)
    if ($srcs | is-empty) { return }
    let tree = (tree-dir)
    let kver = (kernel-version $tree)
    step "building kernel modules"
    let toolchain = (toolchain (base-dir) $kver)
    let dir = (build-dir)
    let dst = ($tree | path join usr lib modules $kver updates)

    for src in $srcs {
        let name = ($src | path basename)
        let layer = ($src | path dirname | path dirname | path basename)
        let out = (workspace | path join modules $"($layer)-($name)")
        let key = {
            toolchain: $toolchain
            files: (glob ($src | path join "**/*") --no-dir | sort | each { |f| [($f | path relative-to $src) (open --raw $f | hash sha256)] })
        } | to nuon
        let stamp = (workspace | path join modules $"($layer)-($name).key")
        if ($stamp | path exists) and (open --raw $stamp) == $key {
            print $"  ($layer)/($name) unchanged"
        } else {
            rm -f $stamp
            compile $src $dir $kver $out
            $key | save --force $stamp
            print $"  ($layer)/($name) built"
        }
        ns-run - sh -c $"mkdir -p '($dst)' && cp '($out)'/*.ko.zst '($dst)/'"
        let cc = ($out | path join compile_commands.json)
        if ($cc | path exists) { cp $cc ($src | path join compile_commands.json) }
    }
    ns-run - depmod -b $tree $kver

    for ko in (glob ($dst | path join "*.ko.zst")) {
        let name = ($ko | path basename | str replace ".ko.zst" "")
        let used = (^modinfo -b $tree -k $kver -F filename $name | str trim)
        if not ($used | str contains "/updates/") {
            error make { msg: $"module ($name): the kernel would still load ($used)" }
        }
        for f in (missing-firmware $tree $kver $name $ko) {
            print $"  (ansi yellow)warning:(ansi reset) module ($name) asks for firmware ($f), which the image does not have - see its modules/($name)/ directory"
        }
    }
}
