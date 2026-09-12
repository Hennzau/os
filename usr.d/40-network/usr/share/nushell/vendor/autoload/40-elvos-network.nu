# Wi-Fi (iwd), the WireGuard VPN (wg0) and the ssh agent, for every nushell.

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

# Set up the VPN from a wg-quick config file (see elvos-wg-enroll --help).
def "vpn enroll" [
    config: path
    --manual                # do not bring it up at boot
] {
    let args = if $manual { ["--manual"] } else { [] }
    run0 elvos-wg-enroll ...$args ($config | path expand)
}

def "vpn up" [] { run0 networkctl up wg0 }

def "vpn down" [] { run0 networkctl down wg0 }

def "vpn status" [] {
    if not ("/sys/class/net/wg0" | path exists) {
        return { tunnel: "not enrolled" }
    }
    {
        tunnel: (open --raw /sys/class/net/wg0/operstate | str trim | if $in == "down" { "down" } else { "up" })
        egress_ip: (do --ignore-errors { ^curl -s --max-time 8 https://ifconfig.co } | default "" | str trim)
    }
}
