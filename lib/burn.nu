# Writing the image to a disk - a USB stick to boot or install from. As mkosi
# burn does it: systemd-repart copies the image's partitions onto the device
# under a fresh partition table that spans all of it, so the stick's free
# space is there for first-boot repart to use.

use common.nu *

export def main [target: path, --yes] {
    let img = (out-dir | path join $"(image-name)_x86-64.raw")
    if not ($img | path exists) { error make { msg: "no image - run `elv build` first" } }
    let target = ($target | path expand)
    let need = (ls $img | get size | first)

    # A plain file is burned as a disk image, as us: handy for trying the
    # result in a VM, and for testing burn itself.
    let device = (($target | path type) == "block device")
    if $device {
        let disk = (^lsblk -J -d -b -o PATH,TYPE,SIZE,MODEL,TRAN $target | from json | get blockdevices | first)
        if $disk.type != "disk" {
            error make { msg: $"($target) is a ($disk.type), not a whole disk" }
        }
        # Any mount on it or its partitions - which is always the case for
        # the disk the running system lives on.
        let mounted = (^lsblk -nr -o MOUNTPOINTS $target | lines | where { $in != "" } | uniq)
        if ($mounted | is-not-empty) {
            error make { msg: $"($target) is in use, mounted at: ($mounted | str join ', ')" }
        }
        if ($disk.size | into filesize) < $need {
            error make { msg: $"($target) holds ($disk.size | into filesize), the image needs ($need)" }
        }
        let what = ([$disk.model? $disk.tran? ($disk.size | into filesize | into string)] | compact | str join ", ")
        print $"  ($target): ($what)"
    } else if not ($target | path exists) {
        error make { msg: $"($target) is neither a disk nor an existing file - for a file, make one the size of a stick first, e.g. `truncate -s 16G ($target)`" }
    } else if (ls $target | get size | first) < $need {
        error make { msg: $"($target) is smaller than the image \(($need))" }
    }

    if not $yes {
        # No terminal to ask on counts as no: --yes is how scripts say yes.
        let answer = (try { input $"Erase everything on ($target) and write (image-name) to it? [y/N] " } catch { "" })
        if ($answer | str lowercase) not-in [y yes] { print "  nothing written"; return }
    }

    # No definitions: repart would otherwise read the host's own repart.d and
    # lay out partitions of this machine's choosing. With none, it copies
    # the image's partitions as they are.
    let defs = (workspace | path join burn.d)
    mkdir $defs

    step $"writing (image-name) to ($target)"
    let cmd = [systemd-repart --offline=yes --empty=force --dry-run=no --no-pager
        --definitions $defs --copy-from $img $target]
    if $device { ^run0 ...$cmd } else { run-external ...$cmd }
    print $"  done - ($target) boots (image-name); its menu has the Installer entry"
}
