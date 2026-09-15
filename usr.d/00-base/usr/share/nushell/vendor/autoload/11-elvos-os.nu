# `os`: which image this machine is running, and what is in the other slot.
# Every source it reads is world-readable - `bootctl list` and
# `systemd-sysupdate list` both want root, and this answers the same question
# without it.

# systemd's EFI vendor GUID, on every LoaderXxx variable.
const LOADER_GUID = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

# An EFI variable's value: four bytes of attributes, then UTF-16.
def efi-loader-var [name: string]: nothing -> any {
    let file = $"/sys/firmware/efi/efivars/($name)-($LOADER_GUID)"
    if ($file | path exists) {
        open --raw $file | bytes at 4.. | decode utf-16le | str replace --all "\u{0}" ""
    }
}

# /usr/lib/os-release, where IMAGE_ID and IMAGE_VERSION are ours: it is part
# of the /usr that is mounted, so it names *this* image, not the disk's newest.
def os-release []: nothing -> record {
    open --raw /usr/lib/os-release
    | lines
    | parse --regex '^(?<key>[A-Z_0-9]+)=(?<value>.*)$'
    | reduce --fold {} { |kv, acc| $acc | insert $kv.key ($kv.value | str trim --char '"') }
}

# What /usr sits on: the partitions under it (the erofs and its hash tree,
# through the dm device), and whether dm-verity is what maps it - its dm uuid
# is CRYPT-VERITY-…, which is as much as a user can prove without root.
def os-usr []: nothing -> record {
    let mounted = (^findmnt -n -o SOURCE,FSTYPE /usr | str trim | split row --regex '\s+')
    let dev = (^readlink -f ($mounted | get 0) | path basename)
    let slaves = $"/sys/block/($dev)/slaves"
    let uuid = $"/sys/block/($dev)/dm/uuid"
    {
        fstype: ($mounted | get 1? | default "")
        # The device itself too: /usr is not always behind dm (a plain image,
        # a container), and then it is the partition.
        backing: ([$dev] | append (if ($slaves | path exists) {
            ls $slaves | get name | path basename
        } else { [] }))
        verity: (($uuid | path exists) and ((open --raw $uuid) | str starts-with "CRYPT-VERITY"))
    }
}

# Both /usr slots, from the labels repart wrote: `<id>_<version>` on the
# erofs partition, `_verity` and `_verity_sig` beside it, and `_empty` for a
# slot nothing has been written to yet.
def os-slots []: nothing -> table {
    let id = ((os-release).IMAGE_ID? | default "")
    if ($id | is-empty) { return [] }
    let backing = (os-usr).backing
    ^lsblk -J -l -o NAME,PATH,PARTLABEL | from json | get blockdevices
    | each { |d| { name: $d.name, partition: $d.path, label: ($d.partlabel | default "") } }
    | where { |d| (($d.label | str starts-with $"($id)_")
        and not ($d.label | str ends-with "_verity")
        and not ($d.label | str ends-with "_verity_sig")) }
    | each { |d| {
        version: ($d.label | str substring (($id | str length) + 1)..)
        partition: $d.partition
        running: ($d.name in $backing)
    } }
}

# Is there an empty slot? A freshly installed machine has one until the first
# `elv sysupdate` writes to it.
def os-slot-empty []: nothing -> bool {
    (^lsblk -n -o PARTLABEL | lines | any { |l| ($l | str trim) == "_empty" })
}

# The running image at a glance. The other slot is what a reboot would give
# you after `elv sysupdate`.
def os []: nothing -> record {
    let release = (os-release)
    let usr = (os-usr)
    let version = ($release.IMAGE_VERSION? | default "?")
    let slots = (os-slots)
    let here = ($slots | where running | get 0?)
    let other = ($slots | where running == false | get 0?)
    {
        image: $"($release.IMAGE_ID? | default '?') ($version)"
        kernel: (sys host | get kernel_version)
        usr: ([
            ($here.partition? | default "?")
            $usr.fstype
            (if $usr.verity { "dm-verity" } else { "unverified" })
        ] | str join ", ")
        # The UKI systemd-boot chose. A `+N-M` suffix means this boot is still
        # being counted; a plain name means it was blessed good.
        booted: (efi-loader-var LoaderEntrySelected | default "not booted by systemd-boot")
        other: (if $other != null {
            let newer = ($other.version != $version
                and (([$version $other.version] | sort --natural | last) == $other.version))
            $"($other.version) on ($other.partition)" + (if $newer {
                " - newer, reboot to run it"
            } else {
                " - the previous one"
            })
        } else if (os-slot-empty) {
            "empty - the next elv sysupdate writes it"
        } else {
            "unknown"
        })
    }
}
