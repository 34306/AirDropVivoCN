# vivo X300 Ultra CN AirDrop — KernelSU module

AirDrop on the **vivo X300 Ultra CN (V2547A)** through Google Quick Share, packaged
as a flashable KernelSU module. The original package drove everything over `adb`
with scripts; this module runs the same steps on the phone.

## The one rule

Nothing is written to a system partition and nothing is remounted read-write.
Every change is one of:

* a **read-only OverlayFS** mount whose `upper`/`work` trees live on a private
  tmpfs (`/mnt/vivo-airdrop`), or
* a **read-only single-file bind** of a file that lives on `/data`, or
* a **tmpfs** holding the global Wi-Fi firmware image set.

A reboot drops all of it. The module relies on KernelSU boot hooks and a
`sepolicy.rule`, so it does **not** need the meta-overlayfs metamodule and does
**not** use the module `system/` directory.

> On a locked bootloader a single write to a system partition is unrecoverable.
> This module never writes to one: the only file it changes is a *copy* on
> `/data` (used as the source of a read-only bind), the overlay upper/work trees
> and the Wi-Fi firmware set live on tmpfs, and the one `touch` is on
> `/apex/apex-info-list.xml`, which is a tmpfs (verified on the target device).
> The EROFS/dm-verity partitions are only ever mounted *over*, never written.

## Requirements

* vivo X300 Ultra CN, model **V2547A**, Android 16 (API 36).
* KernelSU / KernelSU Next, **late-load** (jailbreak-style root that appears
  after Android has booted). Standard KernelSU is also handled.
* Google Play services installed and Quick Share usable.

`customize.sh` refuses to install on any other model or API level.

## Why this needs a refresh

On this device the root only appears **after** Android has booted, so the
overlays are placed too late for PackageManager and servicemanager to notice.
The module therefore:

1. mounts the overlays from the `late-load` stage, then
2. asks for **one** `ksud soft-reboot` per kernel boot, and
3. lets that emulated boot re-read everything (its `post-fs-data` stage runs with
   the framework stopped, so PM rescans the privileged app, servicemanager
   re-reads the VINTF fragment and SystemConfig re-reads the CN feature), then
4. runs the Wi-Fi / app half from the `boot-completed` stage of that refreshed
   boot.

The refresh is recorded per `boot_id`, so it happens once per real boot and never
in a loop. Every step is also idempotent within a boot: the overlays are detected
and skipped, the refresh is recorded once, and the daemon and the Wi-Fi bring-up
no-op when already in place — so extra `ksud soft-reboot`s are harmless.

## How to use

1. Install the zip in the KernelSU manager.
2. Activate root (the same way you normally do — `ksud late-load`). The module
   mounts the overlays and triggers the refresh; the screen will go through a
   quick Android restart. Wi-Fi then drops for a few seconds during the driver
   swap.
3. On the Mac or iPhone set AirDrop to **Everyone for 10 minutes**; on the phone
   share a file and pick Quick Share (to receive: Quick Share ▸ Receive, screen on).

The manager's **Action** button prints the state and repeats the flow without a
reboot (mount overlays → refresh, or bring-up if already refreshed).

## What gets overlaid

* `/product/priv-app/MoseyApp/` — the four Mosey APK splits.
* `/product/etc/permissions/` — the priv-app allowlist and the hidden-API exemption.
* `/system_ext/lib64/libmosey_daemon_ffi.so` and
  `/system_ext/etc/vintf/manifest/manifest_mosey.xml`.
* `/product/etc/sysconfig/cn_feature.xml` — the `<feature name="cn.google.services"/>`
  element is **removed** so Quick Share is not gated behind the CN feature
  (`cmd package has-feature cn.google.services` becomes `false`). The ROM file is
  untouched; a patched copy on `/data` is bound read-only over it.
* `/vendor/firmware_mnt/image/peach` — the global Wi-Fi firmware image set.

## Layout

| Path | Role |
| --- | --- |
| `late-load.sh` | mounts the overlays, then requests one `ksud soft-reboot` |
| `post-fs-data.sh` | (re)mounts the overlays with the framework stopped; writes the per-boot marker |
| `service.sh` | starts the `mosey_server` supervisor and the boot-loop watchdog |
| `boot-completed.sh` | firmware bind, kernel modules, Wi-Fi driver swap, app grant/start |
| `action.sh` | status + mount/refresh/bring-up, run from the manager |
| `uninstall.sh` | restore the CN Wi-Fi driver, unload modules, drop all mounts |
| `sepolicy.rule` | the SELinux rules the `mosey_server` binder service needs |
| `bin/common.sh` | the shared library (all mount/undo logic lives here) |
| `bin/server.sh` | keeps `mosey_server` running |
| `bin/watchdog.sh` | clears the boot-loop counter once `sys.boot_completed=1` |
| `payload/` | APK splits, allowlists, `mosey_server` + lib + VINTF fragment, `.ko`s, Wi-Fi firmware |
| `src/` | GPL source of `wonder_shim.ko` |

State that has to survive a reboot (log, CN XML backup, per-boot markers) lives in
`/data/adb/vivo-x300u-airdrop/`; the runtime copy of `mosey_server` is staged in
`/data/local/tmp/airdrop/`, the same place the `adb` flow used.

## Troubleshooting

* Log: `/data/adb/vivo-x300u-airdrop/airdrop.log`.
* If Android does not come back after the refresh, open `adb` and remove
  `/data/adb/modules/vivo-x300u-airdrop/disable` (create it to disable the module),
  or delete the module folder while the framework is down.
* The kernel modules are built with `CONFIG_MODVERSIONS`: the release string is
  not compared, symbol CRCs are. The module therefore tries to load them and logs
  the result instead of hard-rejecting a kernel whose build string differs from
  the one the package was documented against.
* If the firmware bind fails, `bringup` refuses to load the global Wi-Fi driver
  and puts the phone's own driver back instead. The bind is also verified to
  report `WLAN.GNG.2.0-01536` before the driver is touched, because the CN
  firmware asserts on the Passthru (wondertap) vdev and vivo then reboots.
* If Wi-Fi does not come back, run the Action button and read the log/dmesg; the
  CN driver is restored by `uninstall.sh` or by rebooting.

## Licensing

`payload/` bundles binaries from vivo, Qualcomm and Google taken from the
official firmware, plus `wonder.ko` (GPL, AOSP `common-modules/wonder`),
`qca_cld3_peach_v2.ko` (qcacld-3.0, CodeLinaro) and the module's own
`wonder_shim.ko` (GPL-2.0, source in `src/`). Share privately with owners of the
same device only.
