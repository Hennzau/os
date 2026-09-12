# Defaults for every nushell on the system: vendor autoload files run before
# the user's own config, which can override any of this.
$env.config.show_banner = false
$env.EDITOR = "nano"
$env.VISUAL = "nano"

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
