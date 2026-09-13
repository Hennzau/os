# The root tree: a copy of the package tree, with the layers applied and /usr
# made hermetic - everything the image needs at boot must live under /usr,
# because /usr is the only thing that ships.

use common.nu *

export def pacman-conf []: nothing -> path {
    let c = (config)
    let conf = (workspace | path join pacman.conf)

    # mkosi's cache, when present, is read as an extra cache so test builds do
    # not download what this machine already has. Downloads go to the first,
    # writable CacheDir.
    let mkosi = ($env.HOME | path join ".cache/mkosi/arch~rolling~x86-64/cache/pacman/pkg")
    let extra = if ($mkosi | path exists) { $"CacheDir = ($mkosi)\n" } else { "" }

    $"[options]
Architecture = x86_64
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 8
DisableSandbox
CacheDir = (cache-dir)
($extra)
[core]
Server = ($c.mirror)/$repo/os/$arch

[extra]
Server = ($c.mirror)/$repo/os/$arch
" | save --force $conf
    $conf
}

# pacman's trust store for this workspace, populated from the host's
# archlinux-keyring. Separate from the host's, so nothing here touches /etc.
export def keyring []: nothing -> path {
    let gpg = (workspace | path join gnupg)
    if ($gpg | path join .populated | path exists) { return $gpg }

    step "initialising the pacman keyring"
    mkdir $gpg
    ns-run - pacman-key --gpgdir $gpg --init
    ns-run - pacman-key --gpgdir $gpg --populate archlinux
    touch ($gpg | path join .populated)
    $gpg
}

# What the image's fixed shape needs, whatever the layers list: mkfs.vfat,
# for the ESP systemd-sysinstall creates on the disk it installs to.
const BUILTIN_PACKAGES = [dosfstools]

export def layer-packages []: nothing -> list<string> {
    $BUILTIN_PACKAGES | append (layers
    | each { |l| $l | path join packages }
    | where { path exists }
    | each { open --raw | lines | str trim | where { |p| $p != "" and not ($p | str starts-with "#") } }
    | flatten)
    | uniq
}

# pacman on a tree, with its API filesystems mounted. `initramfs` is a virtual
# package the kernel depends on; claiming it is installed keeps mkinitcpio out
# - the initrd is built from its own tree instead.
def --wrapped pacman-in [tree: path, ...args: string] {
    (ns-run $tree pacman --root $tree --config (pacman-conf) --gpgdir (keyring)
        --noconfirm --needed --assume-installed initramfs ...$args)
}

# Install packages into a fresh tree. With --dbs, from that directory of sync
# databases instead of downloading new ones: the tree gets exactly the
# versions those databases name, from the package cache, without the network.
export def bootstrap [tree: path, packages: list<string>, --dbs: path] {
    if ($tree | path exists) { ns-run - rm -rf $tree }
    mkdir ($tree | path join var lib pacman)
    let sync = if $dbs != null {
        ^cp -a $dbs ($tree | path join var lib pacman sync)
        "-S"
    } else { "-Sy" }

    step $"installing ($packages | length) packages into ($tree)"
    pacman-in $tree $sync ...$packages
}

# The package tree: what pacman installs for the layers, and nothing else. It
# persists between builds, and pacman only runs on it when the package set
# changes, so a change to a layer's usr/ never waits on pacman. Its sync
# databases move only with --update: that is the one way packages change
# version, and the only step that needs the network.
export def base [--update] {
    let dir = (base-dir)
    let stamp = (workspace | path join base.nuon)
    let dbs = ($dir | path join var lib pacman sync)
    let want = (layer-packages)
    let have = if ($stamp | path exists) and ($dbs | path exists) { open $stamp } else { null }
    let dropped = if $have == null { [] } else { $have | where { $in not-in $want } }
    let added = if $have == null { $want } else { $want | where { $in not-in $have } }

    if $have == null or ($dropped | is-not-empty) {
        # pacman could remove them, but a tree that has had packages removed
        # is not quite a tree that never had them. Start over, from the same
        # databases unless updating, so dropping one package upgrades nothing.
        rm -f $stamp
        if $have == null or $update {
            bootstrap $dir $want
        } else {
            let saved = (workspace | path join sync)
            rm -rf $saved
            ^cp -a $dbs $saved
            bootstrap $dir $want --dbs $saved
            rm -rf $saved
        }
    } else if $update {
        step "updating the package tree"
        pacman-in $dir -Syu ...$added
    } else if ($added | is-not-empty) {
        # Against the databases the rest of the tree came from, so adding a
        # package is never a partial upgrade.
        step $"adding ($added | str join ' ')"
        pacman-in $dir -S ...$added
    }
    $want | to nuon | save --force $stamp

    let synced = (ls ($dbs | path join core.db) | first | get modified | date humanize)
    print $"  ($want | length) packages, package databases dated ($synced)"
}

# Copy a layer's usr/ over the tree's /usr, as namespace root so every file
# ends up owned by root in the image. .keep files only hold empty directories
# in git. Templates are rendered in, never copied.
export def apply-usr [src: path, tree: path] {
    if not ($src | path exists) { return }
    ns-run - sh -c $"tar -C '($src)' --exclude=.keep --exclude='*.tmpl' -cf - . | tar -C '($tree)/usr' -xpf -"
    render-templates $src ($tree | path join usr)
}

# The values templates are rendered with: every vars/*.yaml (or .yml), each
# holding its own top-level keys - palette:, font: - merged into one record.
# A key two files both define is an error, not a silent override.
export def template-vars []: nothing -> record {
    let dir = (project | path join vars)
    if not ($dir | path exists) { return {} }
    glob ($dir | path join "*.{yaml,yml}") | sort | reduce --fold {} { |f, acc|
        let data = try { open $f | default {} } catch { |e|
            error make { msg: $"vars/($f | path basename): not valid YAML \(($e.msg))" }
        }
        let twice = ($data | columns | where { $in in $acc })
        if ($twice | is-not-empty) {
            error make { msg: $"vars/: ($twice | str join ', ') defined again in ($f | path basename)" }
        }
        $acc | merge $data
    }
}

# One template's text, rendered: every {{ a.b.c }} - or {{ .a.b.c }}, the Go
# spelling elvOS's templates use - becomes that value from vars/. Anything
# else between braces is left as it is. A missing value, or one that is a
# list or a map rather than a scalar, stops the build and names the file.
def render [file: path, vars: record]: nothing -> string {
    let text = (open --raw $file)
    let name = ($file | path relative-to (project))
    let refs = ($text
        | parse --regex '(?<whole>\{\{\s*\.?(?<key>[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)\s*\}\})'
        | uniq-by whole)
    $refs | reduce --fold $text { |r, acc|
        let value = ($vars | get -o ($r.key | split row "." | into cell-path))
        if $value == null {
            error make { msg: $"($name): no value for ($r.key) in vars/" }
        }
        if ($value | describe) not-in [string int float bool] {
            error make { msg: $"($name): ($r.key) is a ($value | describe), not a single value" }
        }
        # Literal, not regex, replacement: a $ or \ in a value stays as it is.
        $acc | str replace --all $r.whole ($value | into string)
    }
}

# Every *.tmpl under src, rendered into dst at the same place minus the
# .tmpl, with the template's own mode. (A file that must keep a .tmpl name
# is shipped as NAME.tmpl.tmpl.)
def render-templates [src: path, dst: path] {
    let templates = (glob ($src | path join "**/*.tmpl") --no-dir)
    if ($templates | is-empty) { return }
    let vars = (template-vars)
    let stage = (workspace | path join rendered)
    for t in $templates {
        let rel = ($t | path relative-to $src | str replace --regex '\.tmpl$' '')
        let out = ($stage | path join $rel)
        mkdir ($out | path dirname)
        render $t $vars | save --force --raw $out
        let mode = (^stat -c %a $t | str trim)
        ns-run - sh -c $"install -D -m ($mode) '($out)' '($dst | path join $rel)'"
        print $"    ($rel) \(rendered)"
    }
    rm -rf $stage
}

# The image speaks what the layers' factory locale.conf says (usr.d/00-base:
# usr/share/factory/etc/locale.conf), and nothing else: those locales are
# compiled, PID 1 gets the same variables, and every other language's
# translations, the locale sources and translated man pages go - over 100 MB.
export def locales [tree: path] {
    let conf = ($tree | path join usr share factory etc locale.conf)
    if not ($conf | path exists) { return }
    let vars = (open --raw $conf | lines
        | parse --regex '^(?<key>LANG|LC_[A-Z_]+)=(?<value>.+)$'
        | update value { str trim --char '"' })
    let wanted = ($vars | get value | uniq)

    # localedef takes seconds, so its output is kept, keyed on the glibc it
    # was compiled for: a build only copies three megabytes.
    let glibc = (ls (base-dir | path join var lib pacman local) | get name | path basename | where { $in =~ '^glibc-[0-9]' } | first)
    let key = { glibc: $glibc, locales: $wanted } | to nuon
    let cached = (workspace | path join locale-archive)
    let stamp = (workspace | path join locale-archive.key)
    let archive = ($tree | path join usr lib locale locale-archive)
    if ($cached | path exists) and ($stamp | path exists) and (open --raw $stamp) == $key {
        ns-run - cp $cached $archive
    } else {
        for l in $wanted {
            let parts = ($l | split row ".")
            ns-run - chroot $tree localedef -i ($parts | first) -f ($parts | last) $l
        }
        cp $archive $cached
        $key | save --force $stamp
    }

    # PID 1 reads /etc/locale.conf as it starts, before tmpfiles has linked
    # it in, so it and every service it starts would run in C.UTF-8 -
    # systemd-sysinstall, which carries the locale over, among them. Its own
    # configuration is read from /usr. (The kernel command line would do too,
    # but localectl then warns that it overrides locale.conf.)
    let manager = ($tree | path join usr lib systemd system.conf.d)
    mkdir $manager
    let assignments = ($vars | each { |v| $"($v.key)=($v.value)" } | str join " ")
    $"[Manager]\nDefaultEnvironment=($assignments)\n" | save --force ($manager | path join 10-locale.conf)

    # Translations are kept for these languages alone: en_US.UTF-8 keeps
    # en_US and en.
    let langs = ($wanted | each { split row "." | first } | each { |l| [$l ($l | split row "_" | first)] } | flatten | uniq)
    let keep = ($langs | each { |l| $"! -name '($l)'" } | str join " ")
    let share = ($tree | path join usr share)
    ns-run - sh -c ($"rm -rf '($share)/i18n' && "
        + $"find '($share)/locale' -mindepth 1 -maxdepth 1 ! -name locale.alias ($keep) -exec rm -rf {} + && "
        + $"find '($share)/man' -mindepth 1 -maxdepth 1 ! -name 'man*' ($keep) -exec rm -rf {} +")
}

# The /etc paths tmpfiles fills from the factory at boot: C and L lines on
# /etc with no source of their own, in any of the image's tmpfiles.d files -
# ours (lib/usr/lib/tmpfiles.d/etc.conf), Arch's arch.conf, and whatever a
# layer adds.
def factory-paths [tree: path]: nothing -> list<string> {
    glob ($tree | path join usr lib tmpfiles.d "*.conf")
    | each { open --raw | lines } | flatten | str trim
    | where { $in =~ '^[CL][-+!?=~^]*\s+/etc/' }
    | each { split row --regex '\s+' }
    | where { |f| ($f | length) < 7 or $f.6 == "-" }
    | each { |f| $f.1 | str replace --regex '^/etc/' '' }
    | where { not ($in | str contains "*") }
    | uniq
}

# fontconfig's caches, built with the image and kept in /usr, where
# lib/usr's 05-elv-cache.conf points fontconfig. fc-cache writes to the
# first writable cache directory, /var/cache/fontconfig, so they are moved
# from there. A cache is valid while its font directory's mtime is unchanged
# - and /usr's never changes.
export def font-cache [tree: path] {
    if not ($tree | path join usr bin fc-cache | path exists) { return }
    let cache = ($tree | path join usr lib fontconfig cache)
    ns-run - sh -c ($"rm -rf '($tree)/var/cache/fontconfig' '($cache)' && "
        + $"chroot '($tree)' fc-cache --system-only --really-force > /dev/null && "
        + $"mkdir -p '($cache)' && mv '($tree)'/var/cache/fontconfig/* '($cache)'/")
}

export def set-os-release [tree: path] {
    let c = (config)
    let file = ($tree | path join usr lib os-release)
    let kept = (open --raw $file | lines | where { |l| not ($l =~ '^(IMAGE_ID|IMAGE_VERSION|DEFAULT_HOSTNAME)=') })
    # DEFAULT_HOSTNAME is the hostname as long as /etc/hostname sets none:
    # PID 1 and hostnamed read it from here, so /etc needs no file for it.
    $kept | append [$"IMAGE_ID=($c.id)" $"IMAGE_VERSION=($c.version)" $"DEFAULT_HOSTNAME=($c.id)"] | str join "\n" | $in + "\n" | save --force $file
}

# Unit enablement lands in /etc/systemd as symlinks, and /etc does not ship.
# Move it under /usr/lib/systemd, where it takes effect from the image itself.
export def relocate-enablement [tree: path] {
    for scope in [system user] {
        let src = ($tree | path join etc systemd $scope)
        let dst = ($tree | path join usr lib systemd $scope)
        if not ($src | path exists) { continue }

        let entries = (ls -a $src | where { |e| ($e.name | str ends-with ".wants") or ($e.name | str ends-with ".requires") or $e.type == symlink })
        for e in $entries {
            let name = ($e.name | path basename)
            if ($e.name | str ends-with ".wants") or ($e.name | str ends-with ".requires") {
                ns-run - sh -c $"mkdir -p '($dst)/($name)' && cp -a '($e.name)/.' '($dst)/($name)/' && rm -rf '($e.name)'"
            } else {
                ns-run - sh -c $"rm -f '($dst)/($name)' && cp -a '($e.name)' '($dst)/($name)' && rm -f '($e.name)'"
            }
        }
    }
}

# At boot, systemd-sysusers creates the system users afresh from sysusers.d,
# before anything copies /etc/passwd in. One with a fixed number there gets
# the build's number back; one numbered dynamically may not (alpm, avahi, git,
# pcscd and qemu came out different). A file in /usr owned by such a user
# would belong to someone else at boot: say so.
def check-owners [tree: path] {
    let fixed = (glob ($tree | path join usr lib sysusers.d "*.conf")
        | each { open --raw | lines } | flatten
        | parse --regex '^[ugm]\s+(?<name>\S+)\s+(?<id>\d+)' | get name | uniq)
    let names = { |file|
        open --raw ($tree | path join etc $file) | lines | parse "{name}:{x}:{id}:{rest}"
        | reduce --fold {} { |e, acc| $acc | insert $e.id $e.name }
    }
    let users = (do $names passwd)
    let groups = (do $names group)
    # Through sh: ns-run hands its arguments to nushell, which would parse the
    # parentheses.
    let owned = (ns-run - sh -c $"find '($tree)/usr' \\\( ! -uid 0 -o ! -gid 0 \\\) -printf '%U %G %p\\n'" | lines)
    for line in $owned {
        let f = ($line | split row " ")
        for owner in [[($users | get -o ($f | get 0)) "user"] [($groups | get -o ($f | get 1)) "group"]] {
            let name = ($owner | first)
            if $name != null and $name != "root" and $name not-in $fixed {
                print $"  (ansi yellow)warning:(ansi reset) ($f | skip 2 | str join ' ' | str replace $tree '') is owned by ($owner | last) ($name), numbered dynamically - its number may differ at boot"
            }
        }
    }
}

export def hermetic [tree: path] {
    step "making /usr hermetic"
    set-os-release $tree

    ^systemctl --root $tree preset-all out> /dev/null err> /dev/null
    # And the per-user units (pipewire and friends): --global writes the same
    # kind of symlinks under /etc/systemd/user, which relocate-enablement
    # moves into /usr as well.
    ^systemctl --root $tree --global preset-all out> /dev/null err> /dev/null
    relocate-enablement $tree

    # pacman's database describes what is in /usr, so it moves with /usr; a
    # tmpfiles rule links it back into /var at boot so `pacman -Q` works.
    let local = ($tree | path join var lib pacman local)
    if ($local | path exists) {
        ns-run - sh -c $"mkdir -p '($tree)/usr/lib/pacman' && rm -rf '($tree)/usr/lib/pacman/local' && mv '($local)' '($tree)/usr/lib/pacman/local'"
    }

    # The factory copy of /etc holds exactly what tmpfiles puts in /etc at
    # boot, and nothing else. Each entry comes from /etc as the packages left
    # it - so PAM, the CA store, pacman.conf follow the packages - unless a
    # layer ships its own under usr/share/factory/etc, which wins: what is
    # ours is a file in the repo.
    let factory = ($tree | path join usr share factory etc)
    let list = (workspace | path join factory.list)
    factory-paths $tree | where { |p| ($tree | path join etc $p) | path exists }
    | each { $"./($in)" } | str join "\n" | save --force $list
    ns-run - sh -c $"rm -rf '($factory)' && mkdir -p '($factory)' && tar -C '($tree)/etc' -cf - -T '($list)' | tar -C '($factory)' -xpf -"
    for l in ([(project | path join lib usr)] | append (layers | each { path join usr })) {
        let own = ($l | path join share factory etc)
        if ($own | path exists) {
            ns-run - sh -c $"tar -C '($own)' --exclude=.keep --exclude='*.tmpl' -cf - . | tar -C '($factory)' -xpf -"
            render-templates $own $factory
        }
    }

    check-owners $tree

    # The verity signature is checked in userspace against these, in the
    # initrd and after switching root.
    let verity = ($tree | path join usr lib verity.d)
    mkdir $verity
    cp (keys-dir | path join db.crt) ($verity | path join $"((config).id).crt")

    # bootctl install picks the .signed copy when there is one, so a system
    # installed from this image (systemd-sysinstall) gets a boot loader that
    # passes Secure Boot. The image's own ESP is staged from it too.
    let boot = ($tree | path join usr lib systemd boot efi systemd-bootx64.efi)
    (^sbsign --key (keys-dir | path join db.key) --cert (keys-dir | path join db.crt)
        --output $"($boot).signed" $boot) e>| ignore
}

export def main [--update] {
    if not (keys-dir | path join db.key | path exists) {
        error make { msg: "no signing key yet - run `elv keys` first" }
    }

    base --update=$update

    # Every build starts from a pristine copy of the package tree, so nothing
    # a layer or the finalisation did last time can leak into this one. On
    # btrfs or xfs the copy shares extents with the original: about a second.
    let tree = (tree-dir)
    step "copying the package tree"
    ns-run - sh -c $"rm -rf '($tree)' && cp -a --reflink=auto '(base-dir)' '($tree)'"

    step "applying layers"
    apply-usr (project | path join lib usr) $tree
    for l in (layers) {
        print $"  (($l | path basename))"
        apply-usr ($l | path join usr) $tree
    }

    locales $tree
    font-cache $tree
    hermetic $tree
    print $"  kernel (kernel-version $tree)"
}
