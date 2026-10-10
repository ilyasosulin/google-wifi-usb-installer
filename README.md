# Google WiFi: install OpenWrt from a USB stick with the reset button

Install OpenWrt on the eMMC of a Google WiFi (`ipq40xx/chromium`, `google_wifi`)
**without ssh, scp and dd commands**: boot the router from a USB stick, wait for
the LED to turn cyan, press the reset button twice. The router writes OpenWrt to
its eMMC, verifies it and reboots into it.

This is an addition to the standard OpenWrt image, not a fork of it: three small
shell files on top of the official image, built with the official ImageBuilder.
It is written with inclusion into OpenWrt in mind (see
[Towards upstream](#towards-upstream)).

## Why

The [current procedure](https://openwrt.org/toh/google/wifi) after booting from
USB is: `scp` the image to the router, then
`dd if=/dev/zero bs=512 seek=7634911 of=/dev/mmcblk0 count=33 && dd if=image of=/dev/mmcblk0`.

- It needs a Linux/Unix shell, ssh and scp.
- `seek=7634911` is the last 33 sectors of **one particular eMMC size**. eMMC sizes
  differ between units: of the two routers tested here, one has 7 634 944
  sectors, the other 7 733 248. On the larger one the command zeroes sectors in
  the middle of the disk, and the stale backup GPT of the stock firmware stays at
  the real end of the eMMC. On a smaller eMMC the first `dd` fails and nothing is
  installed.
- The image on the stick and on the eMMC get identical partition GUIDs. The kernel
  command line is `root=PARTUUID=<kernel partition>/PARTNROFF=1`, so with the
  stick still plugged in the eMMC kernel may mount the root filesystem of the
  stick. Hence "remove your USB drive".
- `dd` writes only the length of the image. If the eMMC held OpenWrt before, the
  old overlay (settings) can survive behind the new squashfs.

The installer reads the eMMC size from the device, writes a GPT with fresh GUIDs
and the backup GPT at the real end, copies only the kernel and the squashfs,
marks the overlay area so that it is created fresh, and verifies the result.

## Usage

1. **Get an image**: download `*-google_wifi-squashfs-factory.bin` from
   [Releases](../../releases), or [build it](#building).
2. **Write it to a USB stick** as a raw image: `dd` on Linux/macOS,
   [Rufus](https://rufus.ie) in *DD image* mode on Windows, or the Chromebook
   Recovery Utility ("use local image"). Any size stick works; its content is lost.
3. **Boot the router from the stick** - developer mode and USB boot as described
   on the [OpenWrt wiki page](https://openwrt.org/toh/google/wifi). This step is
   unchanged.
4. Wait about a minute until the **LED is cyan**. The system on the stick does no
   further setup: LAN is 192.168.1.1, Wi-Fi is off.
5. **Press reset twice** (two short presses within two seconds).
6. The LED **blinks red fast** while installing (about 15 seconds), then **blinks
   green three times** and the router reboots into the eMMC system. The stick may
   stay plugged in; it can be used for the next router.

| LED | Meaning |
| --- | --- |
| cyan | running from the USB stick, waiting for a double press of reset |
| fast blinking red | installing |
| 3 × green, then reboot | installed and verified |
| solid red | failed **before** writing - the eMMC was not changed |
| slow blinking red | failed **while** writing - boot from the stick and press reset twice again |

A long press of reset (5 s or more) keeps its usual meaning: on the stick it
erases the stick's overlay. Normal reset behaviour on the eMMC system is not
changed.

### After installation

The first boot from eMMC is a normal first boot of OpenWrt. With the optional
[setup code](#optional-setup-code-from-the-label) script the router is
reachable at once:

- **Wi-Fi** `OpenWrt-XXXX` (2.4 GHz, WPA2; `XXXX` - last 4 hex digits of the MAC
  on the label), password = the **setup code** printed on the label of the router;
- **root password** for LuCI and ssh = the same setup code.

Change both after the first login. Without the script (or if the setup code
cannot be read) the router behaves like stock OpenWrt: Wi-Fi off, no root
password, LAN at 192.168.1.1.

## Troubleshooting

- **Log**: from another machine `ssh root@192.168.1.1 logread -e usb-installer`,
  or `/tmp/usb-installer.log`. The router does not reboot after an error.
- **Dry run**: `usb-installer check` on the router running from USB performs all
  checks, writes nothing and prints the partition table it would write.
- **Stale settings on the stick** (an unexpected LAN address or hostname while
  running from USB): `dd` writes only the length of the image, so an overlay from
  an OpenWrt that booted from this stick earlier may survive a rewrite. Hold reset
  for 5+ seconds while running from the stick to erase it. This does not affect
  the installation: the installer never copies the stick's overlay.
- **Manual way**: the procedure from the wiki still works.

## Upgrades: sysupgrade

The `*-sysupgrade.bin` from the same build is a normal OpenWrt sysupgrade image
and can be used on a router already running OpenWrt, whether it was installed
with this installer or by hand:

- On the eMMC system the installer does nothing: `/etc/init.d/usb-installer` only
  acts when the overlay lives on a USB disk, and the reset handler falls back to
  the stock behaviour.
- sysupgrade on `google,wifi` writes the partitions named `kernel` and `rootfs` on
  the boot device and leaves the GPT alone, so the fresh GUIDs (and an expanded
  rootfs partition, if you resized it) survive the upgrade.
- With a manually installed router *and* the stick plugged in, both devices carry
  the same PARTUUID and sysupgrade may pick the wrong one - unplug the stick.
  With this installer the GUIDs are unique.

## Building

On Linux x86_64 or WSL, with the
[ImageBuilder prerequisites](https://openwrt.org/docs/guide-user/additional-software/imagebuilder#prerequisites):

```sh
./build.sh                      # OpenWrt 25.12.5
./build.sh -v <version>         # another OpenWrt release
./build.sh --no-setup-code      # without the setup-code script
./build.sh -p "luci-ssl"        # extra packages
```

Images end up in `out/<version>/`. The GitHub workflow in `.github/workflows`
builds the same images (Actions -> Build images -> Run workflow) and publishes
a release when a tag like `v25.12.5-1` is pushed.

To add the installer to your own ImageBuilder setup, copy `files/` into your
`FILES` directory and add `sfdisk` to `PACKAGES`.

## How it works

Files (all in `files/`):

| File | Role |
| --- | --- |
| `usr/sbin/usb-installer` | the installer: `detect`, `ready`, `button`, `check`, `install` |
| `etc/init.d/usb-installer` | at boot: if running from USB, switch the LED to cyan and arm the reset button |
| `etc/rc.button/reset` | the stock reset handler plus one hook line for the installer |
| `etc/uci-defaults/99-google-wifi-setup-code` | optional: root password and 2.4 GHz Wi-Fi from the setup code |

Installation steps:

1. **Detection.** fstools mounts the overlay from a loop device inside the rootfs
   partition; if its backing device is `sdX2`, the system runs from USB.
2. **Checks** (nothing written yet):
   - board `google,wifi`, `/dev/mmcblk0` present and writable, none of its
     partitions mounted;
   - the stick has a GPT with exactly two partitions and partition 1 is a
     ChromeOS kernel;
   - partition 2 starts with squashfs and its `bytes_used` fits before the
     overlay offset (the fstools loop offset);
   - the eMMC is large enough;
   - the kernel and the squashfs region of the stick are read completely and
     their md5 is taken.
3. **Partition table.** The stick's layout (`sfdisk -d`) is written to the eMMC
   with new random disk and partition GUIDs, keeping partition names, types and
   ChromeOS attributes (`GUID:48,56` - priority 1, successful). sfdisk places the
   backup GPT at the real end of this eMMC.
4. **Data.** The kernel partition and the rootfs partition up to the overlay
   offset are copied sector by sector. The first 64 KiB of the overlay area are
   zeroed and start with `0xdeadc0de`, so fstools formats a fresh overlay on first
   boot.
5. **Verification.** Page cache dropped, kernel and squashfs read back from the
   eMMC and compared by md5, partition layout and marker checked.
6. 3 × green, `reboot`. The bootloader boots the internal disk by default.

Dependencies: `sfdisk` (package), busybox `md5sum`, `hexdump` or `od`, `dd`,
`awk`, LED `timer` trigger.

## Tested

| Unit | eMMC sectors | OpenWrt | Result |
| --- | --- | --- | --- |
| Google WiFi #1 | 7 634 944 | 25.12.5 | installed in ~12 s, boots from eMMC with the stick plugged in |
| Google WiFi #2 | 7 733 248 | 25.12.5 | installed in ~14 s, boots from eMMC with the stick plugged in |

Reports from other units (especially other eMMC sizes) are welcome - please open
an issue with the output of `usb-installer check` and `sfdisk -d /dev/mmcblk0`.

## Towards upstream

The goal is to make "write the image, boot from USB, press reset twice" the
documented installation method for this device. Possible steps:

1. **Wiki**: document the installer as an alternative method, and fix the
   `seek=7634911` note (eMMC sizes differ).
2. **OpenWrt**: board-specific files for `google,wifi` in
   `target/linux/ipq40xx` - the installer and init script, a hook in the reset
   handler (or a generic "USB install" hook in base-files), `sfdisk` in the
   device packages. Nothing changes for a router running from eMMC.
3. A smaller, separate change: let `sysupgrade` running from a USB-booted system
   target the eMMC, so that `sysupgrade -n image.bin` also works for installation.

The optional setup-code script deliberately stays separate: OpenWrt keeps Wi-Fi
disabled until the user configures it, and this would be a policy change.

## License

GPL-2.0-only, like OpenWrt. See [LICENSE](LICENSE).
