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
  layers' packages install together, before any files are copied. Optional
  `modules/NAME/` directories hold kernel modules built from source (see
  "Kernel modules from source"). A file a
  layer ships under `usr/share/factory/etc/` is an /etc default and wins over
  the package's version (it reaches /etc if a tmpfiles line names it).
- `image.nuon` holds identity only: `id`, `version`, `mirror`.
- **Templates** (2026-09-13): a layer file `NAME.tmpl` is rendered at build
  time into `NAME` (the template's mode kept) and never shipped itself;
  `NAME.tmpl.tmpl` gives a file called `NAME.tmpl`. Values come from
  `vars/*.yaml|yml`, merged, each file bringing its own top-level keys
  (`palette:`, `font:` - elvOS's `theme/*.yml` drop in as they are); a key
  in two files is an error. Placeholders `{{ a.b.c }}` or `{{ .a.b.c }}`
  (elvOS's Go spelling), optionally piped through `| trimPrefix "s"` /
  `| trimSuffix "s"` (2026-09-15: elvOS's fuzzel.ini uses trimPrefix "#";
  before that the renderer knew no pipes and left those ten colour lines
  unrendered in the image - the user found a broken fuzzel.ini); a
  key-shaped placeholder with any other pipe is an error, other `{{ ... }}`
  is left alone; a missing or
  non-scalar value stops the build naming the file; substitution is literal
  (`$`, `\` safe). Done where layer files enter the tree: `apply-usr` and
  the factory `/etc` overlay in `hermetic` (both tar with `--exclude='*.tmpl'`,
  then `render-templates`). Verified with a throwaway layer: nesting,
  int/bool, repeated refs, an executable template (0755), a factory one, the
  .tmpl.tmpl escape, and each error case.
- Nothing outside `/usr` ships: **/etc starts empty** on first boot (the
  root partition is created then, see "Persistent disk") and gets only what
  tmpfiles rules put there, mostly as links into
  `/usr/share/factory/etc`, which holds exactly those entries (see "Minimal
  /etc"); unit enablement is relocated from `/etc/systemd` into
  `/usr/lib/systemd`; the pacman db moves to `/usr/lib/pacman/local` and is
  linked back into `/var` by tmpfiles.
- **One key signs everything** (`keys/db.key` + `db.crt`): UKI, systemd-boot,
  verity root hash, and the PK/KEK/db enrollment files — mkosi does the same.
- **User config files** (decided 2026-09-13, reversing an earlier "no"): a
  templated file is rendered into /usr and put in homes by **user-tmpfiles**
  (**`/usr/share/user-tmpfiles.d/`** - not /usr/lib, which user-tmpfiles never reads: `systemd-tmpfiles --user --cat-config` lists only /usr/share; `%h/...`), run by the user manager's
  systemd-tmpfiles-setup.service at login (enabled from /usr: the user-preset
  `disable *` does not touch it). **Only `L`, no `C`** (user, 2026-09-15:
  "no copy for all of them, only links" - niri's config/monitors, fuzzel,
  GTK settings.ini and mimeapps.list had been `C`): every image's version
  reaches the home and changes are made in the repo; a tool saving settings
  replaces the link with a file, which then stays the user's. `L`, not
  `L+`, which would replace a file the user made. Homes that got `C`
  copies keep them until deleted (L never replaces a file).
  **Everything goes to ~/.config** (user, 2026-09-15):
  nothing of ours in /etc/xdg, even where an app reads it natively - tools
  read and edit the files in the home. They also chose `/usr/lib/…`
  for vendor config with an `/etc` override layer, per systemd's convention.

## Layout

```
elv                 entry point (nushell script, subcommands)
image.nuon          id / version / mirror
vars/               YAML values for layer *.tmpl files: palette.yml (elvOS's,
                    verbatim), fonts.yml (elvOS's, mono -> IBM Plex Mono)
usr.d/NN-name/      layers: packages + usr/ (+ modules/NAME/, kbuild sources)
lib/common.nu       paths, config, ns-run (the user-namespace runner)
lib/ns.nu           runs *inside* the namespace; mounts API fs into a tree
lib/keys.nu         elv keys
lib/tree.nu         bootstrap (pacman), layers, hermetic finalisation
lib/modules.nu      the layers' kernel modules, built in their own tree
lib/initrd.nu       initrd as a second small Arch tree + cpio
lib/uki.nu          ukify build + sbsign; kernel cmdline lives here
lib/image.nu        ESP staging, build-time repart defs, repart, `vm`
lib/vmctl.py        `elv vmctl`: the VM's console/QMP sockets (Python)
lib/burn.nu         elv burn: the image onto a disk (run0) or a file
lib/usr/            built-in layer, applied beneath usr.d: tmpfiles (etc.conf,
                    the /etc whitelist), sysupdate.d transfers, runtime
                    repart.d (A + B slots),
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
./elv build [--update] [--installer]   tree → modules → initrd → uki → image
                         (~8 s warm, ~60 s cold); --installer writes the
                         installer medium instead (see below)
./elv tree [--update] | modules | initrd | uki | image [--installer]   one stage
                         (tree runs modules too)
./elv vm [--serial|--headless] [--install] [--pristine] [--setup-mode]   QEMU window,
                         always Secure Boot; the window is a pristine machine
                         (every first-boot question), --serial/--headless are
                         pre-answered with root autologin unless --pristine
                         (--serial: serial on stdio; --headless: no window),
                         TPM, 4 CPU / 4G, 64G qcow2 overlay; --install adds a
                         blank 64G vdb to install onto
                         blank 64G vdb to install onto; --share DIR offers a
                         host directory to the guest read-only (9p, tag `elv`);
                         firmware has our keys enrolled, --setup-mode none
./elv vmctl VERB         drive a running vm: wait, run, reboot, key, screen,
                         log, quit (see "Testing in the VM")
./elv boot               run0 systemd-nspawn --volatile=yes of the image, in
                         the terminal
./elv burn TARGET [--yes] [--installer]   the image onto a whole disk (via
                         run0) or an existing file; asks first unless --yes
./elv sysupdate [--reboot]  inside an elv system: run0 systemd-sysupdate
                         --transfer-source=out update (needs a newer version)
./elv clean              remove the workspace
```

Outputs in `out/`: `<id>_<ver>_x86-64.raw` (disk), `.efi` (UKI),
`.usr.raw`, `.usr-verity.raw`, `.usr-verity-sig.raw` (sysupdate sources).
With `--installer`, `<id>_<ver>_installer_x86-64.raw` and no split files.

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

- `elv vm` follows mkosi's `Console=gui` (`-nodefaults -device virtio-vga`,
  pipewire audio) but with `-display gtk,gl=on,grab-on-hover=on,...` and a
  virtio tablet - see "Keys in the window" below. swtpm runs `--daemon --terminate`: the socket exists when it returns
  and it exits with QEMU, so no cleanup code. TPM, OVMF vars and overlay are
  fresh every run.
- **Credentials only for scripted runs** (`--headless`, `--serial`, and
  `elv boot`), never the window, never with `--pristine`: root password
  `elv`, autologin, firstboot keymap + timezone from the host, and a
  `systemd.unit-dropin.systemd-homed-firstboot.service` credential whose
  ConditionPathExists= can never hold, so homed does not ask for a user.
  Multi-line values go over SMBIOS base64'd (`io.systemd.credential.binary:`);
  nspawn gets them C-escaped. Also a `serial-getty@hvc0.service` drop-in:
  hvc0 runs `bash -c 'echo elv-vmctl-ready; exec bash --noediting ...'`
  instead of a login - vmctl's readiness marker. The user saw root autologin in the window and
  wanted the real first boot - that is why the window is pristine.
- The boot menu (SMBIOS `io.systemd.boot.timeout=3`) is shown exactly when
  the run is not scripted. `vmctl menu N` picks entry N (Installer = 1).
- The emulated PS/2 keyboard reaches the firmware fine (tested). Keys that
  seemed lost were sent at the wrong time: see the stale-log fact below.
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

Verified with `elv vm --serial --install` (Secure Boot): sysinstall onto vdb,
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
- **The installed ESP needs our loader.conf and enrollment keys copied onto
  it** (2026-09-15, the user missed elvOS's "Enroll key" entry): elvOS was
  burned whole to the disk, so its ESP *was* the image's, with mkosi's
  /loader/keys/auto and its loader.conf. Here repart makes an empty ESP and
  `bootctl install` writes only `#timeout 3 / #console-mode keep` plus
  `default <token>-*` (bootctl-install.c install_loader_config, and it skips
  the file if one exists) - no keys, so systemd-boot showed no enroll entry
  (boot.c secure_boot_discover_keys: it needs `\loader\keys\<dir>` *and*
  setup or audit mode), and none of `editor no`, `console-mode keep`,
  `secure-boot-enroll manual`. So stage-esp now also puts the ESP's
  `loader/` (loader.conf + keys/auto/*.auth) into the image at
  **`/usr/lib/elv/esp/`**, and installer-finish copies it over the new ESP's
  (which drops bootctl's `default` line with it). An already-installed
  machine needs it once by hand: `run0 cp -a /usr/lib/elv/esp/loader/.
  /boot/loader/`. Not yet tested in a VM install.

**An installer medium boots the Installer and nothing else** (2026-09-15,
the user: on a USB the main entry "doesn't make much sense, and it doesn't
even work" - it is a live system whose first boot wants to grow /usr to 8 G
and add a B slot on the stick). `elv build --installer` / `elv image
--installer` writes `<id>_<ver>_installer_x86-64.raw`, `elv burn --installer
TARGET` writes that one. It differs from the normal image in its ESP's
loader.conf alone: one more line, `default *@installer` (systemd-boot
matches the default with a glob - boot.c efi_fnmatch - against entry ids
`<file>@<profile-id>`), so the menu is skipped and the installer boots;
holding a key still shows both entries. Split files are skipped for it.
- **The UKI keeps both profiles there**: systemd-sysinstall installs the UKI
  it booted from, so an installer-only UKI would leave the installed machine
  booting the installer for ever.
- The copy of loader.conf that goes to `/usr/lib/elv/esp` (for
  installer-finish) is always the plain one, so an installed disk boots its
  desktop whatever medium it came from.
- **The enroll entry is absent in `elv vm` by design**: the VM's firmware
  has our keys enrolled, and systemd-boot only offers enrollment in setup or
  audit mode. `elv vm --setup-mode` gives blank variables and shows it.

**Menu titles of equal length** (2026-09-14, the user's wish): systemd-boot
(boot.c) titles a UKI profile "<PRETTY_NAME> (<TITLE>)" - PRETTY_NAME first,
IMAGE_ID/NAME only as fallbacks - and profile 0 without a TITLE as the bare
name; duplicates get " (<version>)" appended; every title is centred in one
column as wide as the longest. So main is `ID=main\nTITLE=Desktop` and the
installer `TITLE=Install`: "Arch Linux (Desktop)" / "Arch Linux (Install)".
systemd-boot's own "Reboot Into Firmware Interface" cannot be renamed
(`auto-firmware no` would hide it); the enroll entry shows only in setup mode.

**`bootctl list` shows a phantom third entry** (2026-09-13, asked about it):
sd-boot names the profile-0 entry by the plain file name
(`elvos_0.1.0_x86-64.efi`), bootctl names it `…efi@main` (our `.profile` has
`ID=main`; ukify adds that itself anyway). So bootctl lists its own as "not
reported/new", the loader's as "reported/absent" - and "(selected)", being
the booted one. Same entry twice, only two entries in the menu. Verified:
`LoaderEntries` = plain, `@installer`, firmware. `set-default …@installer`
does boot the installer, so `@id` works for profiles ≥ 1; for profile 0 use
the plain name - `…@main` matches nothing sd-boot knows, harmless with one
UKI (its fallback is that entry) but it would boot the newest version when
several are installed.

Driving the installer in a test (see "Testing in the VM"): `vmctl run
'bootctl set-oneshot elvos_0.1.0_x86-64.efi@installer'`, `vmctl reboot
--no-wait`, ~15 s for the installer to draw (`vmctl screen` shows it), then `vmctl key
ret` (disk), `vmctl key e r q s e ret` (erase - the console is AZERTY, `a` is
the `q` key), `vmctl key y e s ret`, `vmctl screen` to read it.

## Testing in the VM (2026-09-12)

Start `./elv vm --headless [--install]` in the background
(run_in_background), then drive it with `./elv vmctl`:

```
vmctl wait                 until this boot's shell is up (cold ~22 s)
vmctl run 'cmd'            clean output, exits with the guest's status (~0.2 s)
vmctl reboot [--no-wait]   systemctl reboot, then wait for the new shell (~17 s)
vmctl wait 'regex'         until it appears in this boot's serial output
                           (searched from the last firmware start)
vmctl key e r q s e ret    QMP sendkey
vmctl screen               the console's TEXT, decoded off a screendump (~0.5 s)
vmctl screen f.png         a real screenshot - only for graphics (sd-boot's
                           menu, a Wayland session): images cost ~1.5k tokens
vmctl menu N               pick boot menu entry N (window/--pristine VMs)
vmctl push LOCAL REMOTE    copy a file in (base64 heredoc over hvc0)
vmctl log [console|serial] vmctl quit
```

Never use `vmctl run` for something that kills the shell (reboot, poweroff):
it waits for a marker that never comes.

How it works, and why each piece:
- Two consoles. ttyS0 → `serial.log` (firmware, menu, kernel; boots are counted
  by `BdsDxe: loading`). A `virtconsole` (hvc0) → `console.sock` + `console.log`
  for the shell: systemd's getty generator puts an autologin getty on hvc0 by
  itself (virtio_console is built in), and no kernel output mixes in.
- **Typing into an emulated 16550 is unreliable**: bytes sent quickly sometimes
  arrive twice (`@@b115a30cc` for an 8-hex tag, `@@@`), even paced. virtio
  has flow control; that is why the shell is on hvc0.
- QEMU drops socket input it has not consumed when the client disconnects: keep
  one connection for the whole verb. And it writes guest output to the client
  too: unread, the console stalls - vmctl drains it and reads the log instead.
- `run` sends `cmd`, then `printf '\n@@%s:%s@@\n' <tag> $?`; the marker only
  exists in output. First use per boot sets `set +o emacs +o vi; stty -echo;
  PS1= PS0= PROMPT_COMMAND=` (no readline, so stty echo applies; no prompt;
  no OSC 3008 context sequences). State in `<workspace>/vmctl.state`.
- `vmctl screen` is exact, not OCR: fbcon draws a bitmap font on a fixed
  grid (8x16 → 160x50 at 1280x800). Each cell's commonest colour is its
  background (so colours, bold, reverse all work); the rest is looked up
  among glyphs learned from the guest: once per `uname -r` + vconsole FONT,
  `ready()` writes ASCII + CP437 (its low half spelled out - Python's codec
  gives control chars) + `●✓✗‣…` to tty12 (kmscon owns tty1-6) and pairs
  each cell's bitmap with what `/dev/vcsu12` says the cell holds (not with string positions: some
  characters did not take one cell and shifted everything). Cached in
  `<workspace>/console-glyphs.json`; before the first calibration, kbd's
  `cp850-8x16` stands in (right for ASCII).
- No kbd font is the kernel's built-in VGA 8x16 (`default8x16` got 12 ASCII
  letters wrong). The kernel draws what its font lacks with fallbacks: `●`→
  `*`, `✓`→`v`, `✗`→`x`, `○`/`•` → a shared replacement glyph, read as `?`.
  That is what is on screen, so that is what `screen` reports.
- kbd's consolefonts also holds raw fonts without a PSF header (`*.16.gz`,
  `*.cp.gz`): parsing them as PSF2 spins on a garbage glyph count.
- Boot time, reboot: 4.6 s shutdown→firmware, 4.4 s firmware→kernel (65 MB
  UKI read + verified), 8 s kernel→login. systemd-boot-update.service costs
  1 s every boot because /etc is tmpfs (NeedsUpdate always true).
- The image's loader.conf: `editor no`, `console-mode keep` (as elvOS),
  `secure-boot-enroll manual`; no `timeout` (menu hidden unless a key is held),
  like what bootctl install writes (elvOS's own has `timeout 5`); `timeout 3` cost every boot
  3 s. `elv vm` (window and --serial, not --headless) passes SMBIOS type 11
  `io.systemd.boot.timeout=3`, which systemd-boot honours under Secure Boot,
  so the menu - and the Installer entry - shows in a VM someone watches.
- The VM is ephemeral: overlay, OVMF vars and TPM are recreated every run.

## Keys in the window (2026-09-13)

The user wants the graphical VM to take their keys - niri's Mod+Shift+A
(close-window) closed the VM window instead. The window is now **QEMU's GTK
display with `grab-on-hover=on`**: pointer over the window → QEMU grabs the
keyboard → GTK3's Wayland seat grab creates a
`zwp_keyboard_shortcuts_inhibitor_v1` → niri passes every inhibitable bind to
the guest. Verified with `WAYLAND_DEBUG=1`: `wl_pointer.enter` followed by
`inhibit_shortcuts`. Pointer leaves → grab and inhibitor go.
- Before that it was SDL (as mkosi), which grabs only on a **click** in a
  relative-pointer window or on Ctrl-Alt-G - the user did neither, so nothing
  was inhibited. The tablet had been dropped for that click-grab; with
  hover-grab it is back (absolute pointer, no capture).
- An earlier note here said GTK3 has no inhibit support: **wrong** -
  libgdk-3 speaks the protocol (seat grabs with the keyboard capability).
- The user's niri binds with `allow-inhibiting=false` still reach niri:
  Mod+Escape (toggle-keyboard-shortcuts-inhibit - the escape hatch), Mod+P
  (lock), Mod+Shift+E (quit).
- `show-menubar=off`, `show-tabs=off`: Ctrl-Alt-M brings the menu back.
- **HiDPI** (2026-09-13): QEMU hands the guest the window's size in
  *logical* pixels (`gd_resize_event`: device px / GTK's integer scale), so
  on niri at 1.75 the guest was 1646x1029 and every guest pixel 1.75 panel
  pixels - kmscon's 28 px (sized for the real panel) looked huge. QEMU
  11.1's GTK `scale=` fixes it: with `zoom-to-fit=off` the guest size is
  logical / scale, so `scale=1/<output scale>` (image.nu `host-scale`: niri's
  focused output via `niri msg --json focused-output`, 1 without niri) makes
  a full-screen window the panel's native 2880x1800. QEMU's own fullscreen
  (Ctrl-Alt-F) skips the division; niri's fullscreen does not. Math from
  QEMU's source, option parse verified; the resolution itself not measured
  by Claude (the user closed the test window).

## Locale (2026-09-12)

The user wants **only en_US**, and firstboot to **ask the keymap**.
- **One source**: `usr.d/00-base/usr/share/factory/etc/locale.conf`
  (`LANG=en_US.UTF-8`). `locales` (after the layers, before hermetic) reads
  it from the tree and derives the rest: `chroot tree localedef` for each
  locale it names (1.5 s, so the archive is cached keyed on the glibc
  package in `base/` + the list), the PID 1 drop-in below, and pruning -
  `usr/share/i18n`, and `usr/share/locale/*` / translated man dirs except
  `locale.alias` and that language (`en_US`, `en`). /usr 796 → 663 MB then.
  `usr/share/X11/locale` (compose tables) is not touched.
- In systemd 261, systemd-firstboot runs **after** systemd-tmpfiles-setup, so
  the factory `/etc` is merged when it looks: locale.conf present → no locale
  prompt. Arch's unit is `--prompt-locale --prompt-keymap-auto
  --prompt-timezone --prompt-root-password`; left as is. Verified with no
  credentials: it asks keymap, then timezone (then root password). keymap-auto
  asks only on a VT, not a serial console.
- firstboot asks once: root is persistent since 2026-09-13.
- PID 1 reads /etc/locale.conf *before* tmpfiles merges the factory copy, so
  it and every service ran in C.UTF-8 (sysinstall's summary said "Locale:
  C.UTF-8"). Fixed with `/usr/lib/systemd/system.conf.d/10-locale.conf`,
  `DefaultEnvironment=LANG=en_US.UTF-8`, written by `locales` from locale.conf.
  Not `locale.LANG=` on the kernel cmdline: that worked too, but localectl
  then warns that the command line overrides /etc/locale.conf.
- The keymap prompt may come pre-filled (seen as `us` only in runs with a USB
  keyboard): systemd 261 suggests what the firmware reports.

## First boot, as a real machine sees it (2026-09-12)

Verified in a `--pristine` VM: systemd-firstboot asks keymap → timezone →
root password; then **systemd-homed-firstboot** ("Create a User Account"):
user name, password twice; then a login prompt. The user is homed-managed
(UID in homed's range, `homectl list` active) and in `wheel`.
- homed and userdbd are enabled by upstream presets; homed-firstboot is not
  (Arch ends its presets with `disable *`): `usr.d/00-base/usr/lib/systemd/
  system-preset/80-elvos.preset` enables it (preset-all runs after layers).
- `usr.d/00-base/.../systemd-homed-firstboot.service.d/10-wheel.conf` adds
  `--member-of=wheel`, as elvOS does (elvOS also sets `--shell=/usr/bin/nu`;
  nushell is not in this image's packages yet).
- Installer, pristine: firstboot asks keymap + timezone (root is locked by
  the profile, so no password question), sysinstall's summary shows the
  answers, and the installed system's first boot asks only root password +
  user - keymap/timezone arrive as credentials. Verified with `de`/UTC.
- Homes live on the /home partition (homed LUKS images on btrfs).

## Burn (2026-09-12)

`elv burn` is mkosi's burn: `systemd-repart --offline=yes --empty=force
--definitions=<empty dir> --copy-from=<image> <target>`. The empty
definitions dir matters: without it repart reads the host's own repart.d.
The partitions are copied as they are under a fresh GPT spanning the target.
Guards, in order: whole disk (`lsblk -d`: without `-d` the stacked dm devices
come first - the host's usr verity device was reported as the "type"),
nothing mounted on it or its partitions (`lsblk -nr -o MOUNTPOINTS`, which
covers the running system's disk), big enough, then a y/N prompt (`input`
throws without a terminal - caught as no; `--yes` for scripts). A block
device goes through run0; a file is written as us.

Verified: burn to a 16G sparse file (1.4 s), then booted it in QEMU as
`-device qemu-xhci -device usb-storage,drive=…,removable=on` with no virtio
disk: sda/usb, `/usr` verified from sda4, running; first boot grew A and made
the B slot on the stick (the default entry is a live system; Installer masks
repart). The real-device path (run0) is untested by Claude.

To boot such a file with vmctl, launch QEMU by hand with the same console
layout as `elv vm` (serial file, virtconsole on console.sock/log, qmp.sock in
the workspace) - vmctl only cares about those files.

## Verity signatures (2026-09-12)

**`usr=signed` in the image policy is not enforced at boot.** The initrd
activates /usr through `systemd-veritysetup@usr`, which, when the kernel
rejects the signature (`-ENOKEY` without our key, `-EINVAL` for a bad one),
logs "retrying without" and activates with no signature at all - no
userspace check on this path. Proven: a copy of the image with one base64
character of the signature changed booted *with Secure Boot on*, `/usr`
"verified" (no "with signature").
- Fix: `dm_verity.require_signatures=1` on the cmdline (uki.nu). The kernel
  refuses unsigned verity tables, so the retry fails; the forged copy now
  stops in emergency mode (`-EINVAL`, then `-ENOKEY`), root locked. The
  kernel checks against the platform keyring (the firmware's db):
  `CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG_PLATFORM_KEYRING=y`.
- Consequence, accepted: **the image boots only with Secure Boot** and our
  key in db. Without it nothing vouched for the UKI either. `elv vm` has no
  `--secureboot` flag any more: it is always on.
- The dissect path (sysinstall's mount of the new disk, nspawn, dissect) is
  different: on `-ENOKEY` it validates in userspace against `verity.d`, and
  only activates unsigned if the policy allows. That is what printed
  "device-mapper: reload ioctl on vdb4-2-verity … Required key not available"
  during a non-Secure-Boot install - harmless, and gone with Secure Boot
  (verified: 0 key errors in an install).
- `elv boot` (nspawn on the host) is unaffected: it is the host kernel, and
  the policy there is `usr=signed+verity`.

## Shell: nushell, and run0 (2026-09-12)

- Root: `systemd-firstboot.service.d/10-shell.conf` (usr.d/00-base) adds
  `--root-shell=/usr/bin/nu`, which only changes the existing (factory)
  root entry with `--force` - tested on a scratch /etc. `--force` also
  re-asks whatever it prompts for, so the drop-in drops `--prompt-locale`
  (unwanted anyway); still keymap-auto, timezone, root password. Verified in
  a pristine VM: same questions, `root:...:/usr/bin/nu`.
- First user: homed-firstboot drop-in has `--shell=/usr/bin/nu` (as elvOS).
  `useradd` / `homectl create` still default to bash unless told.
- `usr/share/nushell/vendor/autoload/10-elvos.nu`: no banner, EDITOR nano,
  and the locale - login(1) passes none on and nushell does not read
  /etc/profile.d/locale.sh, so a nu login shell had no LANG. It loads
  LANG/LC_* from ~/.config/locale.conf or /etc/locale.conf when LANG is unset.
- No sudo in the image (base does not pull it in). run0 goes through polkit,
  whose Arch rules make wheel admin: a wheel user's `run0 id` asks their own
  password ("Authenticating as: tester") and gives uid=0 - verified on tty1.
- vmctl: nushell's line editor asks the terminal for the cursor position
  (`ESC[6n`) and waits; nothing answers on hvc0, so a nu login there hangs
  and drops typed-ahead input. Hence the hvc0 bash drop-in above.

## Minimal /etc, LTS kernel (2026-09-12)

The user wants /etc really minimal; ParticleOS was the reference. The old
`C+ /etc` merged all ~970 factory entries (750 of them the CA store).
- Now `lib/usr/lib/tmpfiles.d/etc.conf` - **named to replace systemd's
  etc.conf**, as ParticleOS does - holds systemd's two links (os-release,
  mtab) and `L /etc/<x>` lines (no target = link to /usr/share/factory/etc/<x>)
  for: pam.d security environment login.defs default skel bash.bashrc
  bash.bash_logout inputrc nanorc locale.conf ssl ca-certificates services
  protocols pacman.conf pacman.d ld.so.conf.d fonts xdg. Linked, not copied:
  updates arrive; replace a link with a file to override.
- **A copy and a link for the same path do not mix**: with a separate
  00-elv-etc.conf, systemd's `C! /etc/pam.d` ran first and the `L` then met a
  directory. Arch's filesystem package has its own arch.conf copying passwd,
  group, shadow, gshadow, nsswitch.conf, shells, issue, profile, profile.d,
  ld.so.conf, hosts, host.conf, fstab, crypttab, securetty, arch-release -
  left alone (replacing it would drop whatever Arch adds), so those six are
  not in our list. `ld.so.cache` neither: ldconfig.service rebuilds it at boot.
- Other packages' tmpfiles add their own dirs (audit, polkit-1, tpm2-tss,
  credstore, ssh/ for userdb). Result: /etc = 57 entries, 24 links.
- **The factory holds only what tmpfiles uses** (hermetic, `factory-paths`):
  every `C`/`L` line on an /etc path with no source of its own, in any
  tmpfiles.d file of the tree (ours, Arch's arch.conf, a layer's), copied
  from /etc as the packages left it; then each layer's
  `usr/share/factory/etc/` is laid over it and wins. 41 entries, 839 files
  (the CA store), 4.5 MB - was ~970 entries. Package-owned files (PAM,
  login.defs, services, pacman.conf...) are deliberately not copied into the
  repo: they would stop following package updates. Generated ones (CA
  store, passwd with build-assigned IDs) cannot be.
- **System user IDs are assigned again at boot**, not copied: sysusers runs
  (4.5 s) before tmpfiles (5.4 s), so arch.conf's `C /etc/passwd` finds the
  file already there. Statically numbered users match the build; five
  dynamic ones did not (alpm 978 → 969, avahi, git, pcscd, qemu). Harmless
  while no /usr file is owned by a dynamic user - today only tty (5) and
  dbus (81), both static. `check-owners` (hermetic) warns at build time if
  that ever changes. Pinning build IDs was rejected: once root persists, a
  later image could pin a number an existing system gave someone else.
- **A package whose /usr links into /etc needs its own `L` line** (2026-09-15:
  LibreOffice would not start - "the configuration file
  /usr/lib/libreoffice/program/sofficerc was not found"). Arch puts its
  sofficerc, bootstraprc and psprint.conf in /etc/libreoffice and links to
  them from /usr, and /etc had no such entry, so the links dangled.
  `usr.d/90-apps/usr/lib/tmpfiles.d/90-elvos-apps.conf`: `L /etc/libreoffice`
  (factory-paths then copies the package's own files into the factory).
  **The check, after adding packages**: `find /usr -xtype l -lname '/etc/*'`
  in a booted image - on this one it also reports element-web's
  config.json, which no package ships (it is written by whoever serves the
  app), so that one stays dangling and element-desktop does not care.
- Verified: TLS (curl https → 200), pacman -Q, password login + run0 on
  tty1, pristine first boot → homed user (nu, wheel) logs in; running.
- **Kernel: `linux-lts`** (6.18.50-2-lts, the host's too). The initrd rebuilt
  on the new kernel version by itself; `require_signatures` works the same.
  The LTS kernel does not print "TDX not supported" on serial - test recipes
  must not wait for it.

## usr.d/10-hardware: audio, Wi-Fi, keyboard (2026-09-13)

The user's second layer, for what the hardware and the person at it need:
- packages: pipewire, pipewire-pulse, pipewire-alsa, wireplumber,
  sof-firmware (as elvOS); iwd, moved out of 00-base with
  `21-wireless.network`; keyd.
- keyd's config is elvOS's, verbatim: `/usr/share/elvos/keyd/default.conf`
  with `20-elvos-keyboard.conf` (`d /etc/keyd` + `L+` to it) - vendor config
  in /usr, and it needs no factory entry. Its libinput quirk
  (`90-elvos-keyd.quirks`, marks the virtual keyboard internal) comes too.
- **Per-user units**: pipewire's sockets are enabled by a *user* preset
  (`85-elvos-hardware.preset`), and hermetic now also runs
  `systemctl --root --global preset-all`; relocate-enablement already moved
  /etc/systemd/user into /usr. systemd's default for unmatched user units is
  *enable*, and Arch ships no catch-all there, so the built-in layer adds
  `user-preset/99-elvos-default.preset` with `disable *` (as Arch does for
  system units). Package-shipped wants in /usr (dbus, gpg-agent) are
  untouched by that - disable cannot remove vendor symlinks.
- **Firmware, for this laptop** (Lenovo IdeaPad Pro 5 14AGP11, Strix Point):
  linux-firmware-amdgpu, -realtek (RTL8852BE Wi-Fi + its Bluetooth), -other
  (the amd/, amdtee blobs), sof-firmware. 115 MB in /usr/lib/firmware, against
  ~1.5 GB for the whole `linux-firmware` (Intel alone 132 MB) - that meta
  package is the line to add if an installer stick must boot other machines.
- **amd-ucode** installs to /boot, which does not ship, so uki.nu passes
  `--microcode` (glob `<tree>/boot/*-ucode.img`) and the UKI gets a `.ucode`
  section (300 KB, a cpio holding kernel/x86/microcode/AuthenticAMD.bin, the
  path the kernel's early loader reads). **Untested on hardware**: a KVM guest
  applies no microcode, and logs none.
- **qemu-guest-agent** with its channel wired in `elv vm`
  (`virtserialport,name=org.qemu.guest_agent.0` on the console's virtio-serial
  bus, socket `<workspace>/qga.sock`) - verified: `guest-ping` and
  `guest-get-osinfo` answer.
- Verified in a VM: keyd + iwd active, `/etc/keyd/default.conf` → the /usr
  file, and for a user `pipewire.socket`/`pipewire-pulse.socket` active,
  starting pipewire + wireplumber on demand (`pactl info` → "PipeWire
  1.6.8", null sink, since a headless VM has no sound device).
- **bluez + bluez-utils** (bluetooth.service by preset) and **fwupd**
  (D-Bus activated, no preset needed). In a VM bluetooth.service stays
  inactive - `ConditionPathIsDirectory=/sys/class/bluetooth`, no adapter -
  and `bluetoothctl` then waits forever for the daemon: do not call it in a
  vmctl test without `timeout`.
- **Power, brightness, smartcards, all firmware** (2026-09-13):
  power-profiles-daemon (+ python-gobject for powerprofilesctl; it pulls
  upower). Its unit is `WantedBy=graphical.target`, and the default target
  *is* graphical.target (Arch's systemd), so it runs on a console-only
  system too - verified active, `powerprofilesctl set power-saver` works (a
  VM offers only power-saver/balanced). brightnessctl goes through logind.
  ccid + opensc + pkcs11-provider, `pcscd.socket` by preset (verified
  active). Firmware is now the whole `linux-firmware` (+ sof-firmware): 470
  MB in /usr/lib/firmware (Arch ships it zstd-compressed, so erofs gains
  nothing), /usr 1.7 → 2.1 GB.
- Guest drivers need nothing installed: every virtio driver is a module in
  the kernel package (gpu, net, input, snd, console, blk, scsi, rng...), and
  the initrd carries the ones boot needs.

## usr.d/20-fonts: IBM Plex, Noto behind it (2026-09-13)

The user wants one family for everything, as on elvOS: **IBM Plex** (Sans,
Serif, Mono - all in `ttf-ibm-plex`, which also has Sans Arabic, Hebrew,
Devanagari, Thai, JP, KR, TC, Condensed), with **Noto** as the fallback
(noto-fonts, -cjk ~300 MB of the 1.4 GB /usr, -emoji).
- The policy is one visible file, `usr/share/factory/etc/fonts/conf.d/
  59-elvos-fonts.conf` (/etc/fonts is linked to the factory, so a layer's
  file there is live): generic aliases (Plex first, Noto second), system-ui /
  cursive / fantasy assigned to Plex Sans, requests for Adwaita Sans/Mono
  (gtk's hard dependency), Cantarell and DejaVu rewritten to Plex, a weak
  Noto + Noto Color Emoji + Noto CJK SC append behind each Plex family
  (keyed on the Plex family, so named requests get it too), and per-language
  CJK: lang ja/ko/zh-tw/zh-hk appends Plex Sans JP/KR/TC (sans only) and the
  Noto CJK region face, strong, so tagged text ranks them first. Arch ships
  no ordering for Noto CJK's region families, so they tied and **KR won for
  everything** (Chinese, monospace Japanese); untagged Han now gets SC.
  Verified with fc-match for every generic × language, emoji, Devanagari.
  59 = before 60-generic/60-latin, whose prefer lists would otherwise come
  first; after 51-local, so local.conf still overrides.
- **The font cache is built into /usr**: `font-cache` (tree.nu, after
  `locales`) runs `fc-cache --system-only` in the tree and moves the result
  to `/usr/lib/fontconfig/cache`; the built-in
  `lib/usr/share/factory/etc/fonts/conf.d/05-elv-cache.conf` adds that
  `<cachedir>`. fontconfig validates caches by directory mtime, which erofs
  keeps, so every boot would otherwise rebuild them into the tmpfs /var.
  Verified: `fc-cache -v` says "existing cache is valid" for all five font
  dirs, /var/cache/fontconfig stays empty.
- **Test the policy in the VM, not with `chroot tree fc-match`**: the tree's
  /etc/fonts is the package one, not the factory - there Noto/Adwaita won.
- The VT cannot use Plex through the kernel: fbcon draws PSF bitmap fonts
  only. kmscon does it instead - usr.d/30-console, below.

## usr.d/30-console: kmscon on the VTs (2026-09-13)

The user wanted IBM Plex on the VT, so **kmscon** replaces agetty there.
- Preset `85-elvos-console.preset`: `disable getty@.service`, `enable
  kmsconvt@.service`. Enabling installs the unit's `Alias=autovt@.service`,
  which relocate-enablement moves over systemd's own autovt@ symlink in /usr,
  so logind spawns kmscon on every VT it opens (verified: tty2 on `chvt 2`).
  kmsconvt@ has `OnFailure=getty@%i`: a broken kmscon still gives a login.
- `/etc/kmscon` is an `L` link to the factory (`30-elvos-console.conf`);
  `kmscon.conf` there sets `font-name=monospace` (so 59-elvos-fonts.conf
  decides: IBM Plex Mono) and `font-size=28` (pixels; sized for the
  laptop's 2880x1800 14" panel, ~240 dpi; Ctrl-Plus/Minus zoom).
- It picks the **freetype** engine itself (fontconfig, FcFontSort fallback);
  pango is not needed. Verified: Plex Mono, CJK from Noto CJK in double
  cells, box drawing. **Emoji draw as a grey blob**: Noto Color Emoji is a
  colour bitmap font and kmscon renders greyscale.
- **Keyboard**: kmscon follows localed's `X11Layout` over D-Bus, and
  firstboot's vconsole.conf carries `XKBLAYOUT=` (verified: `fr` from the
  `fr-pc` keymap), so no layout in kmscon.conf.
- Not on kmscon: everything before `systemd-user-sessions` - kernel log,
  firstboot, homed-firstboot, the installer, emergency shells - stays on
  fbcon. The login banner says `(pts/0)`: kmscon runs login on a pty.
  `TERM=kmscon` (kmscon-terminfo); remote hosts may not know it.
- vmctl: fbcon draws only the foreground VT and kmscon owns tty1-6, so
  calibration now writes on **tty12** (`chvt 12`, `/dev/vcsu12`, then back).
  `vmctl screen` on a kmscon VT decodes noise; it then says so on stderr -
  use `vmctl screen FILE.png` for those.

## Persistent disk, signed PCRs (2026-09-13)

The user asked for elvOS's disk layout. `lib/usr/lib/repart.d/`: 30-swap
(4-32G, `Encrypt=tpm2`), 40-root (btrfs, `Subvolumes=/var`,
`MakeDirectories=/var/log/journal`, `Encrypt=tpm2`, weight 20000), 50-home
(btrfs, unencrypted - homed encrypts each home - weight 40000), all
`FactoryReset=yes`, labels `%M-swap/root/home` (= `elvos-*`). The cmdline is
`root=dissect`; the policy adds `root=encrypted+absent:swap=encrypted+unused
+absent:home=unprotected+absent`, the filter `root=elvos-*` etc. The
installer profile keeps `root=tmpfs` (profile record `root:`).
- The initrd needed **tpm2-tss** (systemd dlopens it to seal/unseal),
  **btrfs-progs** (repart runs mkfs.btrfs there) and **dm_crypt** (btrfs,
  TPM drivers, XTS are built in). Without them first boot cannot make root.
- **PCR signing**: ukify `--pcr-private-key db.key --pcr-banks sha256` on the
  final build is enough - it derives `.pcrpkey` itself and signs every joined
  profile (one `.pcrsig` each; `ukify inspect` shows both).
- **What the TPM seal is bound to** (luksDump): `tpm2-pubkey-pcrs: 11`,
  `tpm2-hash-pcrs:` empty - repart binds **no PCR 7** by default when a public
  key is found. So a Secure Boot db/dbx change (fwupd dbx update) does not
  lock the disk, but nothing in the policy proves Secure Boot was on. Adding
  `TPM2PCRs=7` would bind it - and with **no recovery key** (none enrolled)
  a dbx update would then lose the disk. Raised with the user, not decided.
- Verified in a VM: first boot → vda8 swap (LUKS, 4G), vda9 root (LUKS, 17G,
  btrfs, subvolumes var, var/tmp, ...), vda10 home (34G); running; reboot →
  "Automatically discovered security TPM2 token unlocks volume", same
  machine-id, users and /var kept.
- **Hostname** = the image id. Arch builds the kernel with
  `CONFIG_DEFAULT_HOSTNAME="archlinux"`, and PID 1 leaves a hostname that is
  already set alone when /etc/hostname and credentials give none - so
  `DEFAULT_HOSTNAME=<id>` in os-release (set-os-release; hostnamed does
  report it as DefaultHostname) never reached the kernel. The cmdline carries
  the kernel's `hostname=<id>`; /etc/hostname still overrides it. Putting our
  os-release into the initrd was tried first and changed nothing.
  `hostname(1)` is not installed; use `hostnamectl`.
- **Secure Boot enrollment is manual** (loader.conf `secure-boot-enroll
  manual`, the user's choice). `elv vm` therefore hands OVMF variables with
  our cert as PK/KEK/db and SB on, made by `virt-fw-vars` run in a chroot of
  the built tree (`enrolled-vars`, image.nu; virt-firmware is in 00-base -
  the host does not have it). `--setup-mode` gives blank variables and shows
  the menu, to try the enroll entry. Verified: menu = Arch Linux,
  Installer, Reboot Into Firmware Interface, "Enroll Secure Boot keys: auto"
  (so `vmctl menu 3`, sent as soon as the menu shows - a `vmctl wait` for
  it first misses the 3 s countdown) → "Custom Secure Boot keys successfully
  enrolled" → reset → SB enabled, running. Without enrollment the default
  entry boots with SB off and /usr's signature cannot verify.
- **Installer with the persistent layout**, verified: sysinstall writes ESP
  + A slot to vdb; the installed system's first boot makes B, swap, root
  and /home there itself (runtime repart.d), TPM token on its root,
  running, /usr from vdb3/vdb4.

## Layers 40-70 (2026-09-13)

**No `elvos` directories** (user, 2026-09-13): files go where the tool they
are for would look under /usr, in the hope that tools read /usr natively
one day - `/usr/share/qmk/userspace`, `/usr/share/distrobox/qmk.ini`
(distrobox's own vendor dir: it reads `/usr/share/distrobox/distrobox.conf`),
`/var/lib/qmk`, `/var/lib/containers/users/<uid>`. Script names
(`elvos-*`) and drop-in file names (`50-elvos.conf`) still carry it.

- **40-network**: nftables (input drop, ICMP, DHCPv6, mDNS, DNS/DHCP from
  `virbr*`/`podman*`, forward only for those bridges, includes
  `/etc/nftables.d/*.conf`). nftables.service shows *inactive (dead)* after
  loading - Arch's oneshot has no RemainAfterExit; `nft list tables` is the
  check. WireGuard: `elvos-wg-enroll [--manual] CONFIG` writes
  `/etc/systemd/network/50-wg0.{netdev,network}` (the templates are heredocs
  in the script - no data directory) and the key as an encrypted credential; **no DNS change** (user's choice). It must
  create `/etc/systemd/network` 0755 *before* its `umask 077`: made 0700,
  networkd (not root) silently ignored every file there ("Permission denied"
  on the .d dirs, no wg0). Verified: wg0 up/down, key from the credential, 6
  policy rules. Wi-Fi: `wifi prefer-5ghz [--off]` - until reboot, iwd
  ranks 2.4 GHz at 0.3: /etc/iwd/main.conf + `[Rank] BandModifier2_4GHz=0.3`
  written to /run/iwd-prefer-5ghz, and a /run drop-in restarts iwd as `env
  CONFIGURATION_DIRECTORY=/run/iwd-prefer-5ghz /usr/lib/iwd/iwd` (iwd reads
  main.conf from that variable; the unit's ConfigurationDirectory= sets it
  to /etc/iwd). Verified on and off via /proc/<iwd>/environ. Also
  wireless-regdb, `elvos-wifi-8021x` (elvOS's without
  the eduroam search, user wanted generic), nushell `wifi`/`vpn` commands.
  ssh: `ssh_config.d/50-elvos.conf` linked; `ssh_config` itself is copied by
  openssh's own tmpfiles (a `L` for it was a no-op). ssh-agent.socket by user
  preset, `SSH_AUTH_SOCK` in environment.d and the nushell autoload.
- **00-base** additions: logind (lid/power key ignored, long press off),
  `DEBUGINFOD_URLS` in the factory `/etc/environment` + environment.d, CLI
  tools, base-devel, btrfs-progs, tpm2-tools, libfido2, sbctl, virt-firmware.
- **50-containers**: podman, distrobox, passt, fuse-overlayfs. Rootless
  storage at `/var/lib/containers/users/$UID` (storage.conf; containers-
  storage expands `$UID`) - the homed home is idmapped and cannot hold
  subuid-owned layers. The directory is made by a `user@.service` drop-in
  (`ExecStartPre=+install -d -m 0711 -o %i`), not a 1777 parent anyone could
  squat. **0711, not 0700**: a box with its own userns (distrobox) runs as a
  subordinate ID, which must traverse it - with 0700 crun failed "Permission
  denied" on `overlay/<id>/merged` (plain `podman run` worked either way). `/etc/containers` is **copied** (`C`), not linked: rootful podman
  writes networks there. Verified: rootless `podman run alpine` as a user.
- **60-virtualization**: libvirt (monolithic libvirtd.socket + virtlogd by
  preset), dnsmasq, dmidecode, virtiofsd; `/etc/libvirt` copied (`C`, libvirt
  writes VM/network definitions); the `/var` dirs the package has are
  recreated by our tmpfiles (its own only has a `z`); polkit rule for wheel.
  Verified: `net-start default`, wheel user `virsh -c qemu:///system` with no
  prompt. The default network is not autostarted (as on Arch).
- **70-qmk**: QMK runs in a **distrobox**, not from /usr - Arch's qmk pulls
  arm-none-eabi-gcc (1.9 GB!), -newlib, avr-gcc, avr-libc: ~2.6 GB, which
  had taken /usr from 1.4 to 2.9 GB of the then 4 GB slot. `/usr/bin/qmk`
  (bash) builds the box on first use - `distrobox assemble create --file
  /usr/share/distrobox/qmk.ini` (archlinux image,
  `additional_packages="qmk"`, the userspace volume at the same path,
  `entry=false`, `init_hooks` emptying pacman's cache - `pacman -Scc
  --noconfirm` would keep it, its default answer is no) - then `exec
  distrobox enter qmk -- qmk "$@"`; the box lands in the user's container
  storage. Verified: first `qmk` builds the box, `qmk --version` → 1.2.0
  from inside, QMK_USERSPACE and the userspace volume visible in the box,
  toolchains there; the box is 5.0 GB of storage (cache emptied, was 5.5).
  Firmware compile and flashing not tried. The user then found `make`
  missing in the box (qmk's package assumes base-devel): the manifest now
  adds `make diffutils which`. `qmk compile` itself only exists once
  `~/qmk_firmware` (QMK_HOME) is a valid clone - the subcommand lives in
  that checkout's lib/python, loaded by qmk_cli - so `qmk setup -y` first.
- **One workspace, one VM**: a second `elv vm` recreates the overlay, TPM
  and sockets of the first - the user's own window VM killed a test VM of
  mine (exit 247). Do not start a VM, vmctl it, or rebuild (the overlay is
  backed by out/*.raw) while the user has one open. `distrobox rm qmk` rebuilds it
  with current packages. The host keeps qmk's udev rules (50-qmk.rules,
  copied from the package: uaccess for bootloaders) and the userspace,
  copied once to `/var/lib/qmk` (wheel, ACL); `QMK_USERSPACE` (qmk_cli
  reads it; distrobox enter passes the host environment) in environment.d
  and a nushell autoload.
- Testing containers as a user from vmctl: `useradd` + `elvos-subid-setup`
  + `loginctl enable-linger`, then **`runuser -u USER -- env
  XDG_RUNTIME_DIR=/run/user/UID ...`** - not `systemd-run -M user@ --user
  --wait`: its transient unit holds conmon, so when the command ends systemd
  kills the container (a distrobox killed in its first-run pacman left a
  stale db.lck: "unable to lock database" on every enter), and with
  `-p KillMode=process` `--wait` never returns while the container lives
  (hung vmctl for 25 min). If the hvc0 shell is stuck, the guest agent still
  answers: guest-exec on `<workspace>/qga.sock` (scratch helper: one JSON
  line per call, then guest-exec-status until exited).
- **User-tmpfiles live in /usr/share/user-tmpfiles.d.** The first desktop
  build had them in /usr/lib/user-tmpfiles.d: ignored, so niri found no
  config at login and wrote its own 27 KB default into ~/.config/niri -
  where `C` then never replaces it. A test user must be fresh after such a
  fix.
- Testing nushell autoload files: `nu -c` (even `-l`/`-i`) does not load
  vendor autoload; `nu -c "source FILE; ..."` does.

## usr.d/80-desktop, 90-apps (2026-09-13)

elvOS's desktop, ported. **80-desktop**: Mesa + Vulkan (radeon, virtio,
swrast), niri, xwayland-satellite, Quickshell, greetd, fuzzel, mako,
wl-mirror, portals (gnome, gtk), xdg-user-dirs-gtk, ibus, gnome-keyring,
udiskie. **90-apps**: alacritty, firefox, nautilus, gnome-disk-utility,
gnome-system-monitor, libreoffice-fresh, element-desktop, discord, jolt
(its daemon is a *user* unit, `jolt.service`, enabled by 90-apps' user
preset - the `disable *` catch-all kept it off before).
/usr 3.3 GB (erofs). The slots were 4 GB; **grown to 8 GB** (2026-09-13,
the user's choice) before any install, since a slot's size is fixed once a
machine is installed. 90-apps is the part to drop if it ever gets tight.
Verified: first boot grows A to 8G and makes B 8G (verity stays 256M: the
hash tree for 8G is ~65 MB); `systemd-repart --dry-run=yes --empty=allow
--definitions=/usr/lib/repart.sysinstall.d /dev/vdb` plans an 8G /usr.
- Where things went (no `elvos` directories; native paths first):
  - the Quickshell QML → `/usr/share/quickshell/desktop/` (`-p` paths in the
    `elvos-*` scripts, which keep their names); `theme/Theme.qml.tmpl` from
    the palette (16 colours map to exact palette keys; `elevated` →
    `bg.editor`) and fonts; wallpaper → `/usr/share/backgrounds/wallpaper.jpg`.
  - greetd: `/usr/share/greetd/{config.toml,niri.kdl}`, a drop-in
    `ExecStart=greetd --config /usr/share/greetd/config.toml`; PAM
    `greetd` in the factory /etc (pam.d is linked).
  - every per-user file → `/usr/share/<app>/`, put in ~/.config by
    `/usr/share/user-tmpfiles.d/80-desktop.conf` (and 90-apps.conf): `C` for
    what gets edited - niri's config.kdl and monitors.kdl, fuzzel.ini, GTK's
    settings.ini, mimeapps.list; `L` for niri's session.kdl, mako's config,
    GTK's gtk.css, alacritty.toml and Zed's settings/keymap/theme (the
    user, 2026-09-15: so changes reach; Zed's settings read-only is fine). (Until 2026-09-15 fuzzel,
    alacritty and settings.ini were factory /etc/xdg templates.)
  - mimeapps.list's source is `/usr/share/applications/mimeapps.list` (read
    natively too, as the XDG default); Firefox policies/autoconfig and `mozilla.cfg.tmpl` (fonts from
    vars) in /usr/lib/firefox; LibreOffice's xcd; environment.d for
    MOZ_ENABLE_WAYLAND / ELECTRON_OZONE_PLATFORM_HINT; udiskie user unit
    (user preset); the udisks rule with elv's labels (`elvos-*`, `elvos_*`,
    `_empty`, `esp`).
  - Not ported: elvos-configd and its service (templates + user-tmpfiles
    replace it), zed's configs (the dev layer is deferred), qmk.ini.
- **tty1**: greetd runs there (`vt = 1`), kmscon too (30-console). The
  greetd drop-in has `After=` + `Conflicts=kmsconvt@tty1.service`, the
  pattern display managers use against getty@tty1. **Do not mask
  kmsconvt@tty1**: preset-all enables it through DefaultInstance and fails
  on a masked unit ("Failed to preset all unit: ... is masked") - which the
  build used to swallow (stderr to /dev/null, exit 1, no message); hermetic
  now prints preset-all's error.
- **VM GPU.** The window uses `virtio-vga-gl` (virgl). Headless defaults to
  plain `virtio-vga` + `-display none`, where screendumps (vmctl screen)
  work - but **niri needs 3D**: on plain virtio-vga it opens no /dev/dri,
  runs with zero outputs (`niri msg outputs` empty) and draws nothing.
  `elv vm --headless --gpu` gives virgl via `-display egl-headless`; then
  QEMU's screendump fails "no surface" for every scanout (kmscon's too), so
  look through niri instead: `runuser -u USER -- env XDG_RUNTIME_DIR=...
  NIRI_SOCKET=<run>/niri.wayland-*.sock niri msg action screenshot-screen
  --path /tmp/x.png`, then `vmctl run 'base64 -w0 /tmp/x.png'` and decode.
- **Verified end to end** (--headless --gpu): greetd on tty1 (kmscon's tty1
  instance stepped aside), the greeter - wallpaper, bar, "elvOS" card with
  elvos-default-user's name filled in - then typing the password (QMP keys)
  logs in: niri-session → niri with ~/.config/niri/config.kdl (45 B, ours)
  including the linked session.kdl, Quickshell shell + background, mako,
  udiskie; the user-tmpfiles links and copies all in place.
- **rtkit** (10-hardware, 2026-09-13): pipewire logged "RTKit error:
  ServiceUnknown" without it. D-Bus activated, no preset; verified: active,
  "Successfully made thread ... RT at priority 20" for pipewire, 0 errors.

## usr.d/95-dev (2026-09-14)

elvOS's dev layer, with each language's server, formatter and debugger from
the system and Zed pointed at them. Packages: rust (+src, analyzer, musl,
aarch64-gnu/-musl targets, cargo-zigbuild), zig + zls, clang (clangd,
clang-format) + musl, cmake, meson, ninja, gdb, lldb, valgrind, python + uv
+ ruff + ty, typst + tinymist, just + just-lsp, bash-language-server +
shellcheck + shfmt, taplo-cli, kdlfmt, yaml-language-server,
vscode-json-languageserver, marksman, qt6-declarative (qmlls), zed. /usr
3.3 → 5.0 GB (8 GB slot).
- Zed: `/usr/share/zed/settings.json.tmpl` (elvOS's settings + `lsp.<id>
  .binary.path` for every server + `node.path`), elvOS's keymap and palette
  theme; user-tmpfiles `95-dev.conf`: all three `L` (read-only for Zed:
  UI changes are not saved - the user's choice, so image changes reach).
- **Server ids** are the adapters' or extensions' `[language_servers.<id>]`:
  rust-analyzer, clangd, ty, ruff, bash-language-server (basher ext),
  yaml-language-server, json-language-server (built in); zls (zig ext),
  tinymist (typst), nu (nu, `nu --lsp`), just-lsp (just), marksman
  (marksman). The **qml** extension takes no binary path - it reads only
  arguments, under the key `qml`, and finds qmlls/qmlls6 on PATH. The
  **toml** and **kdl** extensions have no server: formatters `taplo fmt -`
  and `kdlfmt format -` (both read stdin - verified).
- Python: `language_servers: ["ty", "ruff", "!basedpyright", ...]`, ruff
  formats. Rust: clippy on check. Typst: typstyle, PDF on save.
- gdb: Arch's is built with only `--with-system-gdbinit=/etc/gdb/gdbinit`
  (no gdbinit.d) and ships it empty; the factory `/etc/gdb/gdbinit` holds
  `set debuginfod enabled on` (`L /etc/gdb`).
- bash-/yaml-language-server's /usr/bin entries are **absolute symlinks**
  into /usr/lib/node_modules: checked from the host they look missing;
  resolve them inside the tree.
- **Zed's Restricted Mode**: an untrusted project starts no language server
  ("Waiting for worktree ... to be trusted") until the user trusts it (a
  dialog; "Trust all projects in <dir>" is offered).
  `session.trust_all_worktrees` (default false) skips the check - not set
  in the image; a security choice for the user.
- In the VM, Zed's extension downloads failed "client error (Connect):
  operation timed out" while curl reached the same CDN in 3 s - QEMU's
  user networking, probably IPv6 first; not an image problem. On the next
  start all 12 installed.
- **valgrind** (2026-09-14): Arch's needs glibc's debug info to start,
  fetched through debuginfod - with DEBUGINFOD_URLS set, `debuginfod-find`
  got ld.so's in 3 s and `valgrind /usr/bin/true` exits 0. A `su -l` from
  root came up without the variable although /etc/environment has it (the
  message was valgrind's "a function redirection which is mandatory ...
  cannot be set up"), so 00-base's nushell autoload sets it when unset.
- A transient mirror stall ("Operation too slow" on two .sig files) failed
  two builds in a row; the third went through. No .part files were left.

## Self-hosting (2026-09-12)

The image builds itself, and updates itself to the result. `usr.d/00-base`:
- packages: what elv calls beyond `base` - nushell, sbsigntools,
  systemd-ukify (python, pefile), erofs-utils, mtools (repart fills the vfat
  ESP with mcopy), cpio, polkit (run0), qemu-desktop + edk2-ovmf + swtpm
  (`elv vm`), git, jujutsu; iwd, curl, nano. /usr is now 1.8 GB, the erofs
  914 MB (the slots were 4 GB then, 8 GB now).
- `elvos-subid-setup` + `elvos-subid.service` (from elvOS): subuid/subgid
  ranges for regular users, which `unshare --map-auto` needs.
- `20-wired.network` / `21-wireless.network`: DHCP (the image had no active
  .network file). networkd/resolved/timesyncd are on by upstream preset;
  elvOS's `DNSDefaultRoute=no` is not copied - it relies on elvOS's DNS setup.
- File capabilities survive: pacman in our userns writes v3 caps (rootid =
  60378), but mkfs.erofs reads them inside the same namespace, where the
  kernel returns v2 - the image has plain `cap_setuid=ep` on newuidmap.

**Trying it by hand** (`elv vm --install --share .`, then in the guest):

```
run0 sh -c 'mkfs.ext4 -q /dev/vdb; mount /dev/vdb /var/tmp; chmod 1777 /var/tmp'
run0 sh -c 'mkdir -p /mnt/host; mount -t 9p -o trans=virtio,ro elv /mnt/host'
run0 cp -a /mnt/host /var/tmp/src          # as root: db.key is 0600 and 9p
run0 rm -rf /var/tmp/src/out /var/tmp/src/.jj   # reports the host's uid
run0 chown -R $"(whoami):(whoami)" /var/tmp/src
nano /var/tmp/src/image.nuon               # bump the version
cd /var/tmp/src; $env.XDG_CACHE_HOME = "/var/tmp/cache"; ./elv build
./elv sysupdate                            # polkit asks for your password
systemctl reboot
```

The scratch disk dates from the tmpfs root (half the RAM; a cold build needs
~4 GB plus ~500 MB of downloads). With the persistent root /var/tmp is on
disk, so the first two lines should no longer be needed - not re-verified. The login shell is nushell: `&&` is
not a thing, use `;`. Everything is gone when the VM exits.

Verified again on 2026-09-13 with `--share` (145 s cold build in the guest,
`elv sysupdate`, reboot → 0.1.1 from vda7, verified with signature, running;
the guest pulled newer packages, so its kernel was 6.18.51 against the
host's 6.18.50). Earlier verification, with the repo pushed in instead of
shared (root is tmpfs, so a scratch ext4 on the --install disk was
mounted at /var/tmp): a user in wheel, repo pushed in, version bumped to
0.1.1, cold `elv build` as that user (524 MB downloaded, 180 s), `elv
sysupdate` → B slot relabelled `elvos_0.1.1*`,
`EFI/Linux/elvos_0.1.1_x86-64+3-0.efi`; reboot → IMAGE_VERSION 0.1.1, /usr =
vda7 verified with signature, booted as `+2-1`, systemd-bless-boot marked it
good (renamed to plain `.efi`); two UKIs kept. `/dev/kvm` exists in the
guest (nested), but a nested `elv vm` was not run.

## Verified working (2026-09-11)

Full `elv build` then `elv vm` (Secure Boot), checked from a scripted serial
session inside the guest:

- systemd-boot auto-enrolled our keys (`secure-boot-enroll if-safe`, then),
  reset, booted the signed UKI — `Secure Boot: enabled (user)`. Since
  2026-09-13 enrollment is manual; see "Persistent disk".
- `/usr` = `/dev/mapper/usr`, erofs, `verified (with signature)`.
  The image needs Secure Boot: see "Verity signatures" below.
- `systemctl is-system-running` → `running`, no failed units.
- First-boot repart grows A `/usr` to its slot size (4G then, 8G now) and
  creates the empty B slot (16K / 256M / slot size, labels `_empty`).
- `IMAGE_ID/IMAGE_VERSION` set. (/etc was then a full factory merge; see
  "Minimal /etc" for what it is now.)

To test the same way, use `elv vm --headless` + `elv vmctl` (above), not
fixed sleeps piped into `--serial`.

## Same key and id as elvOS (2026-09-14)

The user will put elv on a second laptop (reset), later this one; both
enrolled elvOS's key. So elv now signs with **elvOS's `mkosi.key`/`mkosi.crt`**
(`elv keys --force --key ~/elvos/mkosi/mkosi.key --cert ~/elvos/mkosi/mkosi.crt`;
`--key/--cert` import a pair - checked to match - and rebuild the .auth
files; replaced keys go to `keys/replaced-<date>/`, never deleted), and the
id is **`elvOS`** (partition labels, image filters, sysupdate's %M, the
hostname fallback all follow; the udisks rule's globs too). Version
26.9.130 (set by the user; elvOS's last was 26.9.29). The workspace moved to
/var/tmp/elv.os/elvOS - the old elvos one is stale.
- Updating the *running elvOS* laptop in place was assessed, not done: its
  /etc keeps elvOS's `L+` links into /usr/share/elvos (pam.d/greetd -
  greeter login -, nftables.conf, ssh drop-in, environment, font policy,
  mirrorlist), which elv's `L` lines would not replace; `elv sysupdate`
  would also need `--definitions` (elvOS's /usr had no sysupdate.d, mkosi
  passed its own). Slots there are 29.3 GB / 400 MB (fits). The user chose
  a fresh install instead.

## Network and debugging tools (2026-09-14)

For a networking course and later Bluetooth debugging on the main laptop.
- 40-network: traceroute, mtr, whois, nmap, arp-scan, tcpdump, socat,
  iperf3, ethtool, wget, net-tools (ifconfig/netstat/arp/route), inetutils
  (telnet/ftp/hostname) - beside iputils (ping, tracepath), bind (dig) and
  openbsd-netcat already there. 90-apps: wireshark-qt (+ wireshark-cli).
- **Wireshark capture as a user**: dumpcap is `root:wireshark` 0754 with
  `cap_dac_override,cap_net_admin,cap_net_raw=eip` - the caps survive into
  the image; the group is **static** (`g wireshark 150` in its sysusers.d),
  so no check-owners warning and the gid matches at boot. The first user
  is created `--member-of=wheel,wireshark` (homed-firstboot drop-in);
  existing users need `homectl update USER --member-of=...` (the list is
  replaced, so include wheel).
- Bluetooth debugging (10-hardware): bluez-utils (bluetoothctl, btmon,
  btmgmt), bluez-deprecated-tools (hciconfig, hcitool - Arch dropped
  hcidump), usbutils (lsusb); 00-base: strace, lsof; pciutils, rfkill, and
  the whole linux-firmware (rtl_bt/ included) were already in.

## Main laptop's Bluetooth: RTL8852BD eco 4 (2026-09-14)

Bluetooth on the IdeaPad Pro 5 14AGP11 had never worked on Linux. It is the
USB half of the RTL8852BE card, `0bda:b853`, and reports `rom_version=3`:
the "8852BD" cut, which needs an **eco 4** patch. linux-firmware's
`rtl8852bu_fw.bin` (checked: 20260910) has eco 1 and 2 only, so btrtl's v2
parser finds nothing (-ENODATA, no message), setup fails, and hci0 stays
DOWN with address 00:00:00:00:00:00 and no mgmt index ("No default
controller available"). `Opcode 0xfcf0 failed: -16` (the MSFT extension)
is a side effect, not the cause. Reported upstream several times
(linux-bluetooth, Fedora, CachyOS); Realtek has not answered.
- **The fix**: Realtek's Windows driver has the patch
  (`rtl8852bd_mp_chip_new.dat`, a `BTNIC003` container of 3 records, each
  with its own load address), and github.com/mihaits/rtl8852bd-bt-linux
  worked out how to send it: per record, `0xfc62` writes the record's
  address into the download buffer pointer at `0x801200cc`, then `0xfc20`
  fragments with plain indices; one lone `0xfc20 [0x80]` commits.
  `usr.d/10-hardware/modules/btrtl/` is Linux 6.18.51's btrtl.c/btrtl.h
  plus that download (our port of it, not their 6.8-based module), taken
  only for 8852B + hci_rev 0xb + USB + rom_version 3 when the parser says
  -ENODATA. Verified on the laptop: HCI 5.4, firmware 0x3C91950E, AirPods
  paired and playing. The chip's firmware lives in RAM: a reboot undoes a
  test.
- **Firmware**: `./make-firmware DRIVER.exe` (in that directory) writes
  `usr.d/10-hardware/usr/lib/firmware/rtl_bt/rtl8852bd_eco4.bin`,
  **gitignored** - Realtek's, not redistributable. It unpacks the Inno Setup
  .exe with innoextract, or, not installed, in a throwaway
  `docker.io/library/archlinux` podman container (both paths verified: same
  bytes). Lenovo's driver used: `4zsd020fqtusgcj0.exe`, Realtek 8852BE
  18.4032.0.3008. A build without the file warns (below).
- Lenovo's site answers 403 to our fetches: the user downloads the .exe.
- **bluetoothd kept stale state** once: started while the patched btrtl was
  still bringing the chip up, it received every found device from the
  kernel (btmon showed MGMT Device Found, even for the AirPods) and created
  none - no `[NEW]`, `pair` gave "Device not available". `systemctl restart
  bluetooth` with the chip up fixed it; the exact check was not found. At
  boot the module sets the chip up before bluetoothd sees it, so it should
  not recur.
- **Wi-Fi/Bluetooth coexistence is not negotiated**: rtw89's
  `/sys/kernel/debug/ieee80211/phy0/rtw89/btc_info` says `BT_FW_coex:0
  (Mismatch, desired:7)` and `igno_bt:1` with this firmware. Audio was fine
  (Wi-Fi on 5 GHz); a scan with Wi-Fi off found 14 devices against 9 with
  it on. Look there first if audio stutters.
- Tests that need root were scripts in `~/bt-eco4/` run by the user with
  run0 (the scratchpad under /tmp/claude-* is not visible to their shell).
  btmon under root plus bluetoothd's debug log (`pkill -USR2 -x
  bluetoothd` toggles it) is what separated "radio hears nothing" from
  "bluetoothd drops what it hears".

## Kernel modules from source (2026-09-14)

`lib/modules.nu`, the `modules` stage, run by `elv tree` and `elv build`
after the tree (`elv modules` alone). Each `usr.d/*/modules/NAME/` (a
`Kbuild` and its sources) is built as an external module:
- in its own tree, `workspace/modules-build`: bash, coreutils, findutils,
  gawk, grep, sed, diffutils, gcc, make and `<pkgbase>-headers` (the
  kernel's `usr/lib/modules/KVER/pkgbase` names the package: linux-lts),
  installed from base's sync databases - headers and kernel are the same
  build, and neither lands in /usr (the headers are 270 MB). Remade when
  the kernel, the databases or modules.nu change (`modules-build.key`).
- `make -C /usr/lib/modules/KVER/build M=/src modules` chrooted there,
  then `strip --strip-debug` and `zstd -19`, as Arch ships its own (the
  stock btrtl.ko.zst is 18 KB; unstripped ours was 900 KB). Each module is
  cached in `workspace/modules/<layer>-<name>` keyed on its files' hashes
  and the toolchain key: a warm build only copies it.
- Installed to `/usr/lib/modules/KVER/updates/`, then `depmod -b`. Arch's
  `/usr/lib/depmod.d/search.conf` is `search updates extramodules
  built-in`, so a module named like an in-tree one replaces it; the stage
  checks with `modinfo -b` that the kernel would load ours, and errors
  otherwise.
- It warns about firmware a module asks for (`MODULE_FIRMWARE`) that the
  image lacks - only what the kernel's own module of the same name does not
  ask for, since that list is linux-firmware's business.
- **Arch's kernel has no CONFIG_MODVERSIONS**: nothing checks at load that a
  replaced module and its callers (btusb → btrtl) agree, and Module.symvers
  CRCs are all zero - an export check there proves nothing. So a module's
  Kbuild guards itself with `$(VERSION).$(PATCHLEVEL)`: btrtl's refuses to
  build for anything but 6.18, and a new linux-lts series means porting
  rtl_download_eco4() onto that kernel's btrtl.c. Module signatures are not
  enforced either (lockdown none), so the unsigned module loads and taints
  the kernel; /usr's verity is what vouches for it.
- Verified on a stand-in workspace (this laptop had no keys/, so no real
  `elv tree`): a package tree of linux-lts alone, then the stage - built
  btrtl (19 KB), warned about the missing eco4 firmware, went quiet once the
  file was in the tree, "unchanged" on the second run, and `modinfo -b`
  resolved btrtl to `updates/btrtl.ko.zst`. The Kbuild guard stops a
  mismatched series ("Kbuild:17: *** btrtl.c is from Linux 6.18 ...").
  Not yet in a booted image.
- The build needs `CONFIG_DEBUG_INFO_BTF_MODULES`' pahole: in the toolchain
  tree it comes with the headers package; a host build without pahole fails
  at "BTF [M]" unless given `CONFIG_DEBUG_INFO_BTF_MODULES=`.

## Hard-won facts — do not relearn these

**Environment**
- `/home/enzolevan` is a systemd-homed **idmapped mount**: it can only hold
  files owned by the user's UID. A root tree (files owned by many UIDs) must
  live outside `~` — hence `/var/tmp`. Plain outputs in `out/` are fine.
- Subuid range: `enzolevan:100000:65536`. Inside `ns-run`, uid 0 = the user
  (60378), 1..65536 = subuids.
- **Stale VM files**: launching `elv vm` in the background and polling at
  once reads the *previous* run's serial.log / qmp.sock. `elv vm` now deletes
  them first thing, but still wait for the new socket. And `grep -c` counts
  lines, not matches - firmware output has few newlines; use vmctl's regexes.
- `pkill -f PATTERN` matches your own shell's command line too (it killed
  the tool call twice): anchor it, `pkill -f '^python3 /path/...'`.
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

- **Never byte-compile inside the repo**: `python3 -m py_compile` on a
  script in usr.d wrote `usr/bin/__pycache__/`, which the layer copy put
  into the image's /usr/bin (the user spotted it). Check syntax with
  `python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" FILE`.
  `__pycache__/` is in .gitignore, but the layer copy does not read that.

**Nushell gotchas (each cost a round trip)**
- `[null zero …]`: bare `null` in a list is the null value — quote it.
- Commas separate list items: `[-machine q35,smm=on]` is four items. Quote.
- In `$"…"`, `(config).id` renders the whole record then `.id`; write
  `((config).id)`. Outside strings `(config).id` is fine.
- A module can't export a command named like the module: use `export def
  main`, callable as the module name.
- A script `main` that forwards flags to an external needs `def --wrapped`.

## Known gaps / next steps

- **Deferred by the user (2026-09-13), keep in mind**: elvOS's extra boot
  entries (live session, verbose logs, `amdgpu.dcdebugmask=0xe10`
  "No PSR + IPS"), `audit=0`, a runtime pacman mirror (`pacman -Sy` in the
  image probably has no server), the dev layer (rust, zig, gcc, gdb, typst,
  python/uv/ruff/ty, just), elvOS's full nushell config and commands, the
  sysext dev workflow, a version bump command, and the desktop items
  (elvos-configd/config.d, udisks rule, Wayland environment). Rejected: an
  alternate DNS (AdGuard), and DNS changes with the VPN.
- **No recovery key** on the LUKS root/swap: TPM only. See "Persistent disk"
  for PCR 7.
- **sysupdate source** is local only (`elv sysupdate`, `--transfer-source`);
  a URL source (with SHA256SUMS + signature) would be the alternative.
- No **version bump** command yet (`image.nuon` version is edited by hand).
- The initrd is ~51 MB compressed and unpruned beyond docs/locales. Its
  modules (initrd.nu) were widened 2026-09-13 after mkosi-initrd's default
  list: vmd, SD/eMMC (mmc_block, sdhci-pci/-acpi), xhci-pci-renesas, and
  i2c-hid-acpi + intel-lpss for laptop keyboards on I2C (USB HID,
  hid-generic, i8042/atkbd, the DesignWare I2C host and pinctrl-amd are
  built in). 42 modules.
- No sysext dev workflow for `usr.d` layers yet (elvOS has `elvos-sysext`,
  staging in `/run/extensions` so nothing persists).
- The cmdline carries `console=ttyS0,115200 console=tty0` (tty0 last, so
  /dev/console is the screen); decide whether a real image keeps the serial one.
- `elv boot` and `elv burn` onto a real device are untested by Claude (run0
  needs interactive auth).
- os-release is Arch's, so menus and the installer say "Arch Linux"; only
  IMAGE_ID/IMAGE_VERSION are ours.
- No firmware for hardware other than this laptop's - see usr.d/10-hardware.
- Early boot, firstboot and the installer still use the kernel's 8x16 font
  (kmscon starts at the login); `FONT=` in vconsole.conf (terminus-font)
  would be the way to improve those.
- Not committed: the repo is `jj git init --colocate`d; commit only when the
  user asks.
