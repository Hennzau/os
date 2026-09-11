# elv.os — context for Claude

A nushell tool, `elv`, that builds Arch Linux images with a hermetic,
verity-signed `/usr`. It replaces mkosi for the user's own OS. The user's
current OS, **elvOS**, is built with mkosi from `~/elvos` (read it when you
need a reference for how something is done there); this project is the
from-scratch successor. Started 2026-09-11.

The user runs elvOS as their daily driver: Arch-based, immutable verity `/usr`,
A/B slots via systemd-sysupdate, UKIs, Secure Boot, systemd-homed, niri +
Quickshell, nushell as login shell. They are expert, like understanding *why*,
and prefer lean code whose comments explain reasons rather than restate code.

## Design, as agreed with the user

- **Arch only, one shape of image.** ESP with signed systemd-boot and a signed
  UKI; erofs `/usr` + dm-verity hash + verity signature partition; sysupdate
  transfers and runtime repart definitions built in. None of that is
  configurable.
- **The only customisation is `usr.d/` layers**, applied in name order. A
  layer is a directory with an optional `packages` file (one pacman package
  per line) and an optional `usr/` tree copied over the image's `/usr`. All
  layers' packages install together, before any files are copied.
- `image.nuon` holds identity only: `id`, `version`, `mirror`.
- Everything outside `/usr` is discarded: `/etc` ships as
  `/usr/share/factory/etc` and is merged at boot by a `C+ /etc` tmpfiles
  rule; unit enablement is relocated from `/etc/systemd` into
  `/usr/lib/systemd`; the pacman db moves to `/usr/lib/pacman/local` and is
  linked back into `/var` by tmpfiles.
- **One key signs everything** (`keys/db.key` + `db.crt`): UKI, systemd-boot,
  verity root hash, and the PK/KEK/db enrollment files — mkosi does the same.
- The user considered a user-tmpfiles split for placement and **rejected it**;
  keep things in one mechanism unless they ask. They also chose `/usr/lib/…`
  for vendor config with an `/etc` override layer, per systemd's convention.

## Layout

```
elv                 entry point (nushell script, subcommands)
image.nuon          id / version / mirror
usr.d/NN-name/      layers: packages + usr/
lib/common.nu       paths, config, ns-run (the user-namespace runner)
lib/ns.nu           runs *inside* the namespace; mounts API fs into a tree
lib/keys.nu         elv keys
lib/tree.nu         bootstrap (pacman), layers, hermetic finalisation
lib/initrd.nu       initrd as a second small Arch tree + cpio
lib/uki.nu          ukify build + sbsign; kernel cmdline lives here
lib/image.nu        ESP staging, build-time repart defs, repart, `vm`
lib/usr/            built-in layer, applied beneath usr.d: tmpfiles,
                    sysupdate.d transfers, runtime repart.d (A + B slots),
                    repart.sysinstall.d (what the installer lays out)
keys/  out/         gitignored
```

Workspace (`base/` package tree, `tree/`, initrd, logs, OVMF vars, VM overlay):
`/var/tmp/elv.os/<id>/`. Package cache: `~/.cache/elv.os/pkg`, plus mkosi's
`~/.cache/mkosi/arch~rolling~x86-64/cache/pacman/pkg` read as an extra
CacheDir so builds rarely download.

## Commands

```
./elv keys [--force]     key, cert, loader/keys/auto/{PK,KEK,db}.auth
./elv build [--update]   tree → initrd → uki → image   (~8 s warm, ~60 s cold)
./elv tree [--update] | initrd | uki | image    one stage
./elv vm [--secureboot] [--serial] [--install]   QEMU window (or serial on
                         stdio), TPM, 4 CPU / 4G, 64G qcow2 overlay; --install
                         adds a blank 64G vdb to install onto
./elv boot               run0 systemd-nspawn --volatile=yes of the image, in
                         the terminal
./elv clean              remove the workspace
```

Outputs in `out/`: `<id>_<ver>_x86-64.raw` (disk), `.efi` (UKI),
`.usr.raw`, `.usr-verity.raw`, `.usr-verity-sig.raw` (sysupdate sources).

## Incremental builds (2026-09-11)

The user edits `usr.d/` far more than anything else and wants that fast. Warm
rebuild after a `usr/` change: ~8 s (tree 3, initrd 0.1, uki 0.7, image 4.5).

- `base/` is pacman's output only, persistent, stamped with the package list
  in `base.nuon`. Package added → `pacman -S` into it against its *existing*
  sync dbs (no partial upgrade). Package dropped → fresh bootstrap from a copy
  of the old dbs (offline, same versions). `--update` → `-Syu`. Nothing else
  syncs, so a normal build never touches the network.
- `tree/` = `cp -a --reflink=auto base tree` (~1 s on the btrfs `/var/tmp`),
  then layers + hermetic. Never mutate `base/` outside pacman.
- The initrd is two archives passed as two `--initrd` to ukify (it pads each
  to 4 bytes, which the kernel needs between compressed and plain cpio):
  `initrd.cpio.zst` from packages, cached on `initrd.key` = kernel version +
  sha256 of the sync dbs + sha256 of `initrd.nu`; `initrd-identity.cpio`, rebuilt
  every time, holds `/dev/console`, `etc/initrd-release` and the verity cert.
  The initrd tree installs from `base`'s sync dbs, so its systemd matches `/usr`.
- `/usr` erofs is built by `mkfs.erofs` directly and fed to repart with
  `CopyBlocks=/.elv-usr.erofs` (path relative to `--root`). With
  `Format=erofs` + `CopyFiles=` repart copies the whole tree to a scratch dir
  first: 7.3 s vs 4.2 s for the stage.
- Copy sync dbs with `cp -a`: pacman uses their mtime for If-Modified-Since.
- `mkfs.erofs -Efragments,dedupe` saves 30 MB but takes 36 s; not worth it.

## Test machines (2026-09-11)

- `elv vm` follows mkosi's `Console=gui`: `-nodefaults -device virtio-vga
  -display sdl,gl=on`, pipewire audio, plus `virtio-tablet-pci` (no mouse
  grab). swtpm runs `--daemon --terminate`: the socket exists when it returns
  and it exits with QEMU, so no cleanup code. TPM, OVMF vars and overlay are
  fresh every run.
- Credentials (both machines): root password `elv`, autologin, firstboot
  locale C.UTF-8, keymap and timezone read from the host (`fr-pc`,
  Europe/Paris) so the VM keyboard matches.
- Unprivileged nspawn is not possible: mountfsd answers `ENAVAIL` for a
  usr-only image, even the host-trusted elvOS one. Hence `run0`, as elvOS's
  `just boot`. Policy `usr=signed+verity`: the host trusts only `mkosi.crt`,
  and systemd falls back to hash-only verity when the policy allows it
  ("…without validating signature is permitted by policy").

## Installer profile (2026-09-11)

The UKI has two profiles: `main` (default, ukify adds its `.profile` itself
when joining - building a separate profile 0 duplicated it) and `installer`
(`TITLE=Installer`), built as small PEs and joined with `--join-profile`.
Installer cmdline = base + mask repart (initrd and host) + locked root
(`passwd.hashed-password.root:!*`, verified: firstboot then skips the password
prompt, still asks locale/keymap/timezone) + `systemd.unit=system-install.target`.

That target runs **systemd-sysinstall** (new in systemd 261): repart with
`/usr/lib/repart.sysinstall.d/` (ESP + A slot, `CopyBlocks=auto`), then
`bootctl link` (the booted UKI, all profiles) and `bootctl install`, which
picks `systemd-bootx64.efi.signed` — hermetic signs it into the tree, and the
image's own ESP is staged from that copy. Needs `mkfs.vfat`: `dosfstools` is
in `BUILTIN_PACKAGES` (tree.nu), installed whatever the layers say.

Verified with `elv vm --serial --install --secureboot`: sysinstall onto vdb,
reboot, firmware boots "Linux Boot Manager" from vdb, `/usr` = vdb4 verified
with signature, SB enabled, running, first boot made the B slot. The
installer screen (screendump via the `-nographic` monitor, `Ctrl-A c`,
`screendump f.png -f png`) lists only the non-boot disk.

**Boot layout after install.** `bootctl link` always writes Type #1 entries
(`/loader/entries/<token>-commit_…{,@1}.conf`, one per profile, `uki
/elvos/…efi` plus one `extra /elvos/*.cred` per credential) and `bootctl
install` writes `default elvos-*`; the varlink `Link` method has no layout
choice, and sysupdate cannot write entries. So a drop-in
(`systemd-sysinstall.service.d/10-elv.conf`) runs sysinstall with
`--reboot=no`, then `/usr/lib/elv/installer-finish`, which finds the ESP with
`uki /$IMAGE_ID/` entries (skipping mounted ones = the installer's own),
moves the UKI to `/EFI/Linux/`, `*.cred` to `/loader/credentials/` (stub
passes those to every UKI - verified with a test credential), deletes the
entries and `/elvos/`, and drops the `default` line. Then it asks for a key;
`SuccessAction=reboot` reboots.
- The drop-in must be `Type=oneshot` with two `ExecStart=`: upstream's unit is
  simple, so `ExecStartPost=` ran *alongside* sysinstall and did nothing.
- `SuccessAction=` goes in `[Unit]`; in `[Service]` it is silently ignored
  ("Unknown key", visible with `systemd-analyze verify`).
- "Exiting first boot settings tool." after "Installation succeeded" is
  sysinstall's own exit text.

Driving the installer in a test: run `elv vm --serial --install` in the
background reading from a FIFO; `bootctl set-oneshot
elvos_0.1.0_x86-64.efi@installer && reboot`; then in the monitor (`Ctrl-A c`)
`sendkey ret` (disk), `e r q s e ret` (erase - the console is AZERTY, `a` is
the `q` key), `y e s ret`, `screendump f.png -f png` to look.

## Verified working (2026-09-11)

Full `elv build` then `elv vm --secureboot`, checked from a scripted serial
session inside the guest:

- systemd-boot auto-enrolls our keys (`secure-boot-enroll if-safe`), resets,
  boots the signed UKI — `Secure Boot: enabled (user)`.
- `/usr` = `/dev/mapper/usr`, erofs, `verified (with signature)`.
  Without Secure Boot it is still verified, via the userspace check against
  `/usr/lib/verity.d/<id>.crt` (kernel logs `-ENOKEY` first — expected).
- `systemctl is-system-running` → `running`, no failed units.
- First-boot repart grows A `/usr` to 4G and creates the empty B slot
  (16K / 256M / 4G, labels `_empty`).
- `/etc` populated from factory (94 entries); `IMAGE_ID/IMAGE_VERSION` set.

To test the same way: pipe commands into `./elv vm --serial` — the serial
console is stdin, and autologin is root. See the pattern used:
`( sleep 40; printf 'cmd\n'; sleep 2; …; printf 'poweroff\n' ) | timeout 100 ./elv vm --serial`.
The window mode logs the serial console to `<workspace>/serial.log`.
Strip ANSI with `sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'`.

## Hard-won facts — do not relearn these

**Environment**
- `/home/enzolevan` is a systemd-homed **idmapped mount**: it can only hold
  files owned by the user's UID. A root tree (files owned by many UIDs) must
  live outside `~` — hence `/var/tmp`. Plain outputs in `out/` are fine.
- Subuid range: `enzolevan:100000:65536`. Inside `ns-run`, uid 0 = the user
  (60378), 1..65536 = subuids.
- `pacstrap` is not installed and not needed; `ns-run` does what
  `pacstrap -N` does. The user offered to add arch-install-scripts; declined.
- `run0` needs interactive auth — you cannot run it. Ask the user.

**Build**
- `unshare --map-auto --map-root-user --fork --pid --mount` gives namespace
  root with the full subuid map. repart and cpio must also run inside it, or
  ownership in the image is wrong.
- The Arch `filesystem` package makes the tree root mode **0555**: create
  things at the top of the tree from inside the namespace, not the host.
- `--assume-installed initramfs` keeps mkinitcpio out of the tree.
- `modinfo -b <tree>` reports module paths through the `/lib → usr/lib`
  symlink; strip on `modules/<kver>/`, not a fixed prefix.
- The kernel needs `/dev/console` in the initramfs; mknod is impossible in a
  user namespace, so `initrd.nu` writes a tiny newc fragment by hand and
  prepends it. **newc has 13 header fields**; a 15-field version broke it once.
- `virtio_blk` and `virtio_pci` are built into Arch's kernel (not in the
  module list); `dm_verity` is `dm-verity.ko` (hyphen).
- repart specifiers `%M`/`%A` = IMAGE_ID/IMAGE_VERSION from the tree's
  os-release, so repart and sysupdate definitions need no templating.
- `--split=yes` splits every partition unless `SplitName=-`; the ESP has it.
- **repart matches existing partitions to definitions by type, in order.**
  Runtime A-slot definitions (10–12) must precede the B slot (20–22), or B's
  definitions claim and resize the A partitions. Happened once.
- `systemd-firstboot` prompts on the console when `/etc` is empty (root is
  tmpfs); `elv vm` answers via SMBIOS credentials, the image stays generic.
- The tree bootstrap prints `fchownat() of /sys/kernel/security/tpm0/... not
  permitted` — tmpfiles touching the bind-mounted `/sys`; harmless.

**Nushell gotchas (each cost a round trip)**
- `[null zero …]`: bare `null` in a list is the null value — quote it.
- Commas separate list items: `[-machine q35,smm=on]` is four items. Quote.
- In `$"…"`, `(config).id` renders the whole record then `.id`; write
  `((config).id)`. Outside strings `(config).id` is fine.
- A module can't export a command named like the module: use `export def
  main`, callable as the module name.
- A script `main` that forwards flags to an external needs `def --wrapped`.

## Known gaps / next steps

- **Root is tmpfs.** Persistent root/home/swap partitions (elvOS has them in
  `~/elvos/usr/lib/repart.d/30-50*`, with `Encrypt=tpm2`) are the next step;
  the cmdline would then drop `root=tmpfs`.
- **sysupdate source**: transfers use `PathRelativeTo=explicit`, so updating
  needs `systemd-sysupdate --transfer-source=<out dir>` — untested. A URL
  source would be the alternative.
- No **version bump** command yet (`image.nuon` version is edited by hand).
- No PCR signing (`--pcr-private-key`) for TPM-bound unlock yet.
- The initrd is 48 MB compressed and unpruned beyond docs/locales.
- No microcode (`amd-ucode`) in the UKI yet — the user's laptop is AMD Strix.
- No sysext dev workflow for `usr.d` layers yet (elvOS has `elvos-sysext`,
  staging in `/run/extensions` so nothing persists).
- The cmdline carries `console=ttyS0,115200 console=tty0` (tty0 last, so
  /dev/console is the screen); decide whether a real image keeps the serial one.
- `elv boot` is untested by Claude (run0 needs interactive auth).
- os-release is Arch's, so menus and the installer say "Arch Linux"; only
  IMAGE_ID/IMAGE_VERSION are ours.
- Not committed: the repo is `jj git init --colocate`d; commit only when the
  user asks.
