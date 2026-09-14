# Defaults for every nushell on the system: vendor autoload files run before
# the user's own config, which can override any of this.
$env.config.show_banner = false
$env.EDITOR = "nano"
$env.VISUAL = "nano"
$env.config.edit_mode = "emacs"
$env.config.error_style = "fancy"
$env.config.rm.always_trash = true
$env.config.table.mode = "rounded"
$env.config.table.index_mode = "auto"
$env.config.table.header_on_separator = false
$env.config.footer_mode = 25
$env.config.completions.algorithm = "fuzzy"
$env.config.completions.case_sensitive = false
$env.config.completions.quick = true
$env.config.completions.partial = true
$env.config.history.file_format = "sqlite"
$env.config.history.max_size = 1_000_000
$env.config.history.isolation = true
$env.config.shell_integration.osc7 = true
$env.config.shell_integration.osc8 = true
$env.config.shell_integration.osc133 = true
$env.config.ls.clickable_links = true
$env.config.cursor_shape.emacs = "line"
$env.config.cursor_shape.vi_insert = "line"
$env.config.cursor_shape.vi_normal = "block"

# What /etc/profile.d/locale.sh does for bash, which nushell does not read: a
# login shell's environment has no locale, since login(1) passes none on.
# The user's own locale.conf first, as there.
if ($env.LANG? | is-empty) {
    let conf = [
        ($env.XDG_CONFIG_HOME? | default ($nu.home-dir | path join .config) | path join locale.conf)
        /etc/locale.conf
    ] | where { path exists } | get 0?
    if $conf != null {
        open --raw $conf | lines | parse --regex '^(?<key>(LANG|LANGUAGE|LC_[A-Z_]+))=(?<value>.*)$'
        | reduce --fold {} { |kv, acc| $acc | insert $kv.key ($kv.value | str trim --char '"') }
        | load-env
    }
}

# Debug symbols on demand - valgrind cannot start without glibc's, and gdb
# wants them too. /etc/environment sets this through pam_env, but not every
# way in gets it (a `su -l` from root came up without it), and nushell does
# not read /etc/profile.d.
if ($env.DEBUGINFOD_URLS? | is-empty) {
    $env.DEBUGINFOD_URLS = "https://debuginfod.archlinux.org"
}
