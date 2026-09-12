# elv.os

Build Arch Linux images with a hermetic, verity-signed `/usr`.

```
./elv keys            # once: signing key, certificate, Secure Boot enrollment files
./elv build           # tree → initrd → UKI → disk image, in out/
./elv build --update  # the same, after syncing and upgrading every package
./elv vm              # boot it in a QEMU window: Secure Boot, TPM (root / elv, autologin)
./elv boot            # or as a container in this terminal (via run0)
./elv vm --install    # with a blank second disk, to try the Installer entry
./elv burn /dev/sdX   # write it to a USB stick (via run0; asks first)
./elv sysupdate       # on a running elv system: update it to the image just built
./elv vmctl run CMD   # run a command in a running vm (start it with --headless for no window)
```

The image shape is fixed: an ESP with signed systemd-boot and a signed UKI, an
erofs `/usr` with dm-verity and a signed root hash, and sysupdate A/B slots.
The boot menu has an Installer entry: the same image, booted into
systemd-sysinstall, which copies it onto another disk.
What goes into `/usr` is yours: each directory in `usr.d/` is a layer with an
optional `packages` list and an optional `usr/` tree, applied in name order.
Identity (`id`, `version`, mirror) lives in `image.nuon`.

Builds run unprivileged, in a user namespace. The trees are built under
`/var/tmp/elv.os/`, never in your home.

The image carries everything `elv` needs, so a running system can build its
own next version and `elv sysupdate` to it (A/B slots, boot counting).

pacman's output is kept between builds and only touched when a `packages`
list changes, so editing a layer's `usr/` rebuilds in about eight seconds.
Packages move to newer versions only with `--update`.
