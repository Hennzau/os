# Wi-Fi (iwd), the WireGuard tunnels and the ssh agent, for every nushell.

# The per-user agent (ssh-agent.socket). The user manager's environment has
# it from environment.d; a console login does not.
if ($env.SSH_AUTH_SOCK? | is-empty) and ($env.XDG_RUNTIME_DIR? | is-not-empty) {
    $env.SSH_AUTH_SOCK = ($env.XDG_RUNTIME_DIR | path join ssh-agent.socket)
}

def wifi-device []: nothing -> string {
    let devices = (ls /sys/class/net | get name | path basename
        | where { |nic| $"/sys/class/net/($nic)/wireless" | path exists })
    if ($devices | is-empty) {
        error make { msg: "no wireless interface found under /sys/class/net" }
    }
    $devices | first
}

# Scan, then list the networks in range.
def "wifi scan" [] {
    let device = (wifi-device)
    iwctl station $device scan
    sleep 3sec
    iwctl station $device get-networks
}

# Connect to a network; iwd asks for the passphrase and remembers it.
def "wifi connect" [ssid: string] {
    iwctl station (wifi-device) connect $ssid
}

def "wifi status" [] {
    iwctl station (wifi-device) show
}

# Forget a network iwd remembers.
def "wifi forget" [ssid: string] {
    iwctl known-networks $ssid forget
}

# Prefer 5 and 6 GHz networks over 2.4 GHz until the next boot; --off goes
# back now. iwd ranks a 2.4 GHz network at 0.3 of its signal strength then.
# It is restarted with its configuration read from /run - /etc/iwd/main.conf
# plus that one setting - so nothing persists. The restart drops the
# connection for a moment, and iwd picks the best-ranked network again.
def "wifi prefer-5ghz" [--off] {
    let conf = "/run/iwd-prefer-5ghz"
    let dropin = "/run/systemd/system/iwd.service.d/50-prefer-5ghz.conf"
    let steps = if $off {
        [$"rm -rf ($conf) ($dropin)"]
    } else {
        [
            $"mkdir -p ($conf) ($dropin | path dirname)"
            $"cat /etc/iwd/main.conf > ($conf)/main.conf 2>/dev/null || true"
            $"printf '\\n[Rank]\\nBandModifier2_4GHz=0.3\\n' >> ($conf)/main.conf"
            # iwd reads main.conf from $CONFIGURATION_DIRECTORY, which the
            # unit's ConfigurationDirectory= sets to /etc/iwd: env replaces it.
            $"printf '[Service]\\nExecStart=\\nExecStart=/usr/bin/env CONFIGURATION_DIRECTORY=($conf) /usr/lib/iwd/iwd\\n' > ($dropin)"
        ]
    }
    run0 sh -c ($steps | append ["systemctl daemon-reload" "systemctl restart iwd"] | str join " && ")
}

# 802.1X (WPA-Enterprise) networks, through elvos-wifi-8021x. The password is
# asked for, never an argument, so it stays out of the history.

# Configure from an eap-config profile (what eduroam CAT and many
# institutions publish): method, CA and server name are in it.
def "wifi 8021x import" [
    file: path              # the .eap-config file
    --identity: string      # your login, usually user@realm
    --force                 # replace an existing configuration
] {
    mut args = ["import" ($file | path expand) "--identity" $identity]
    if $force { $args = ($args | append "--force") }
    run0 elvos-wifi-8021x ...$args
}

# Configure by hand, from a CA certificate and the RADIUS server's name.
def "wifi 8021x add" [
    ssid: string
    --identity: string      # your login, usually user@realm
    --ca: path              # CA certificate, PEM or DER
    --server: string        # RADIUS server name, e.g. radius.example.org
    --method: string = "TTLS"   # TTLS or PEAP
    --inner: string         # Tunneled-PAP (TTLS default), Tunneled-MSCHAPv2, MSCHAPV2 (PEAP default)
    --anonymous: string     # outer identity; default anonymous@<your realm>
    --force
] {
    mut args = ["add" $ssid "--identity" $identity "--ca" ($ca | path expand) "--server" $server "--method" $method]
    if $inner != null { $args = ($args | append ["--inner" $inner]) }
    if $anonymous != null { $args = ($args | append ["--anonymous" $anonymous]) }
    if $force { $args = ($args | append "--force") }
    run0 elvos-wifi-8021x ...$args
}

def "wifi 8021x list" [] {
    run0 elvos-wifi-8021x list | lines | each { from json }
}

def "wifi 8021x remove" [ssid: string] {
    run0 elvos-wifi-8021x remove $ssid
}

# The VPN: as many WireGuard tunnels as you enrol, with the fastest of them
# carrying the traffic (elvos-vpn-watch measures them every 20 s).

def vpn-state []: nothing -> any {
    let f = "/run/elvos-vpn/state.json"
    if ($f | path exists) { open $f } else { null }
}

# The tunnels on disk, which is what there is to say when the watcher is not
# running to measure them.
def vpn-enrolled []: nothing -> list<string> {
    glob /etc/systemd/network/50-wg-*.netdev
    | each { $in | path basename | str replace --regex '^50-wg-(.*)\.netdev$' '$1' }
}

def vpn-not-running []: nothing -> record {
    let names = (vpn-enrolled)
    if ($names | is-empty) {
        { vpn: "no tunnel enrolled", enroll: "vpn enroll CONFIG" }
    } else {
        {
            vpn: $"enrolled: ($names | str join ', ')"
            watcher: "not running - your traffic is not tunnelled; `vpn on` brings it back"
        }
    }
}

# The watcher's state file survives the unit (RuntimeDirectoryPreserve), so
# after `vpn off` it would still name a tunnel as carrying the traffic.
def vpn-running []: nothing -> bool {
    (^systemctl is-active elvos-vpn-watch.service | complete | get exit_code) == 0
}

# In /run, as `wifi prefer-5ghz`: tuning lasts until the next boot. What the
# watcher should always do belongs in the repo - the unit's own Environment=
# - not in a file in /etc that the image knows nothing about.
def vpn-tune-file []: nothing -> string {
    "/run/systemd/system/elvos-vpn-watch.service.d/50-elvos-tune.conf"
}

# A drop-in of the same name in /etc would mask the one in /run (systemd
# takes the highest-precedence copy of each file name), and outlive the boot
# unseen. The first version of this command wrote one there.
def vpn-tune-stale []: nothing -> string {
    "; rm -f /etc/systemd/system/elvos-vpn-watch.service.d/50-elvos-tune.conf"
}

# What the watcher is running with: its defaults, with whatever the drop-in
# above overrides. Everything is kept as a string - it is only shown and
# written back.
def vpn-tuned []: nothing -> record {
    let file = (vpn-tune-file)
    let set = if ($file | path exists) {
        open $file
        | parse --regex 'ELVOS_VPN_(?<key>[A-Z]+)=(?<value>[^\s"]+)'
        | reduce --fold {} { |it, acc| $acc | upsert ($it.key | str lowercase) $it.value }
    } else {
        {}
    }
    {
        margin: ($set.margin? | default "25")
        rounds: ($set.rounds? | default "3")
        interval: ($set.interval? | default "20")
        probe: ($set.probe? | default "1.1.1.1")
        source: (if ($set | is-empty) { "the image's defaults" } else { "tuned, until the next boot" })
    }
}

# Add a tunnel from a wg-quick config file (see elvos-wg-enroll --help).
def "vpn enroll" [
    config: path
    --name: string          # what to call it; default: the file's name
    --manual                # do not bring it up at boot
] {
    mut args = []
    if $manual { $args = ($args | append "--manual") }
    if $name != null { $args = ($args | append ["--name" $name]) }
    run0 elvos-wg-enroll ...$args ($config | path expand)
}

# Every tunnel, as the watcher last measured it.
def "vpn list" []: nothing -> table {
    let state = (vpn-state)
    if ($state == null) or (not (vpn-running)) { return [(vpn-not-running)] }
    $state.tunnels | each { |t|
        {
            tunnel: $t.name
            carrying: (if $t.name == $state.active { "yes" } else { "" })
            up: $t.up
            rtt: (if $t.rtt == null { "-" } else { $"($t.rtt | math round -p 0) ms" })
            average: (if $t.average? == null { "-" } else { $"($t.average | math round -p 0) ms" })
            loss: $"($t.loss)%"
            handshake: (if $t.handshake == null { "never" } else { $"($t.handshake)s ago" })
        }
    }
}

def "vpn status" []: nothing -> record {
    let state = (vpn-state)
    if ($state == null) or (not (vpn-running)) { return (vpn-not-running) }
    {
        carrying: ($state.active | default "nothing")
        why: $state.reason
        pinned: ($state.pinned | default "no (fastest wins)")
        measured: ((($state.updated * 1_000_000_000) | into datetime) | date humanize)
        # Both families: an IPv4 through the tunnel and an IPv6 of your own
        # is a leak, and it is only visible if you look at both.
        egress_v4: (do --ignore-errors { ^curl -s -4 --max-time 8 https://ifconfig.co } | default "" | str trim)
        egress_v6: (do --ignore-errors { ^curl -s -6 --max-time 8 https://ifconfig.co } | default "(none)" | str trim)
    }
}

# Pin the traffic to one tunnel, whatever the measurements say.
def "vpn use" [name: string] {
    run0 sh -c ("install -d -m 0755 /run/elvos-vpn" +
        $"; printf '%s' '($name)' > /run/elvos-vpn/pin" +
        "; systemctl restart elvos-vpn-watch")
}

# Back to the fastest one.
def "vpn auto" [] {
    run0 sh -c "rm -f /run/elvos-vpn/pin; systemctl restart elvos-vpn-watch"
}

# Start the watcher by hand - after enrolling the first tunnel on a system
# where it was skipped at boot, which the enrolment does for you.
def "vpn watch" [] { run0 systemctl restart elvos-vpn-watch }

# A tunnel's own interface, for when one should not even hold a handshake.
def "vpn up" [name: string] { run0 networkctl up $"wg-($name)" }

def "vpn down" [name: string] { run0 networkctl down $"wg-($name)" }

# Every catch-all rule elvos-vpn-watch may have installed, of either family.
# It uses two priorities: 32765 in normal times, 32750 for the moment of a
# switch. Deleting until it fails clears a duplicate left by a crash.
def vpn-rules-del []: nothing -> string {
    ("for f in -4 -6; do for p in 32750 32765; do "
        + "while ip $f rule del priority $p 2>/dev/null; do :; done; done; done")
}

# Stop tunnelling: the watcher goes, its rules go with it, and every tunnel's
# interface goes down. Traffic takes the plain link again - which is what a
# captive portal's login page needs. `ActivationPolicy=up` (what enrolment
# writes) only brings a link up when networkd configures it, so a tunnel
# downed here stays down; `systemctl restart systemd-networkd` would undo it.
def "vpn off" [] {
    let downs = (vpn-enrolled | each { |n| $"networkctl down wg-($n) || true" } | str join "; ")
    run0 sh -c ("systemctl stop elvos-vpn-watch; " + (vpn-rules-del)
        + (if ($downs | is-empty) { "" } else { $"; ($downs)" }))
}

# Tunnel again: the interfaces come back up and the watcher starts, which
# gives the rule to the first tunnel that is up before it has measured
# anything, then moves it to the fastest.
def "vpn on" [] {
    let ups = (vpn-enrolled | each { |n| $"networkctl up wg-($n)" } | str join "; ")
    if ($ups | is-empty) {
        return { vpn: "no tunnel enrolled", enroll: "vpn enroll CONFIG" }
    }
    run0 sh -c ($ups + "; systemctl restart elvos-vpn-watch")
}

# How eagerly the watcher switches tunnels, until the next boot. With no
# argument it shows what is in force; the options accumulate, so raising the
# threshold alone keeps whatever else was set.
#
#   vpn tune --margin 60      a challenger must be 60 ms better to win
#   vpn tune --rounds 5       ...and stay better for 5 rounds in a row
#   vpn tune --interval 30    measure every 30 s
#   vpn tune --reset          back to 25 ms / 3 rounds / 20 s / 1.1.1.1, which
#                             a reboot does by itself
def "vpn tune" [
    --margin: int       # milliseconds a challenger must beat the carrying tunnel by
    --rounds: int       # rounds in a row it must do it for
    --interval: int     # seconds between measurements
    --probe: string     # address pinged through each tunnel
    --reset             # forget all of it
] {
    let file = (vpn-tune-file)
    if $reset {
        run0 sh -c ($"rm -f ($file) " + (vpn-tune-stale)
            + "; systemctl daemon-reload; systemctl restart elvos-vpn-watch")
        return
    }
    let now = (vpn-tuned)
    if ([$margin $rounds $interval $probe] | all { |v| $v == null }) { return $now }

    if ($margin != null) and ($margin < 0) { error make { msg: "--margin cannot be negative" } }
    if ($rounds != null) and ($rounds < 1) { error make { msg: "--rounds must be at least 1" } }
    # Below ~5 s the probe (four pings, up to 3 s each) has not finished
    # before the next round is due.
    if ($interval != null) and ($interval < 5) { error make { msg: "--interval must be at least 5 seconds" } }

    let next = {
        margin: (if $margin == null { $now.margin } else { $"($margin)" })
        rounds: (if $rounds == null { $now.rounds } else { $"($rounds)" })
        interval: (if $interval == null { $now.interval } else { $"($interval)" })
        probe: (if $probe == null { $now.probe } else { $probe })
    }
    let conf = ("[Service]\\nEnvironment=ELVOS_VPN_MARGIN=" + $next.margin
        + " ELVOS_VPN_ROUNDS=" + $next.rounds
        + " ELVOS_VPN_INTERVAL=" + $next.interval
        + " ELVOS_VPN_PROBE=" + $next.probe + "\\n")
    # %b, so printf expands the \n itself.
    run0 sh -c ($"install -d -m 0755 ($file | path dirname)"
        + $"; printf '%b' '($conf)' > ($file)"
        + "; chmod 0644 " + $file + " " + (vpn-tune-stale)
        + "; systemctl daemon-reload; systemctl restart elvos-vpn-watch")
    vpn-tuned
}
