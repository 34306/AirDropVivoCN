#!/bin/bash
# AirDrop on the vivo X300 Ultra CN (V2547A) through Google's Quick Share interop (Mosey).
#
#   ./airdrop.sh           bring everything up (same as "up")
#   ./airdrop.sh status    show what is loaded and running
#   ./airdrop.sh down      unload it and put the phone's own Wi-Fi driver back
#
# Needs adb and python3 on the computer, Google Play services on the phone, and a phone whose
# `adb shell` already runs as root (KernelSU). Set SERIAL=... when several phones are connected.
# Nothing is written to a partition and nothing is remounted read-write: kernel modules,
# read-only bind/overlay mounts and SELinux rules live in RAM, so a reboot removes all of it.
# Run it again after every reboot, once root is back.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
if [ -d "$DIR/payload" ]; then ROOT=$DIR; else ROOT=$(dirname "$DIR"); fi
G=artifacts/global-PD2547F-16.0.6.19
D=/data/local/tmp/airdrop
EXPECTED_MODEL=V2547A
EXPECTED_KERNEL=6.12.58-android16-6-g650e74cc80ec-abogki503021821-4k
SERVICE=com.google.android.moseyservice.IMoseyService/default
MOSEY=com.google.android.mosey

die() { echo "ERROR: $*" >&2; exit 1; }
pick() {
    for p in "$@"; do [ -e "$ROOT/$p" ] && { echo "$ROOT/$p"; return 0; }; done
    die "missing file: $1"
}
SHIM=$(pick payload/kernel/wonder_shim.ko shim/out/wonder_shim.ko)
QCA=$(pick payload/kernel/qca_cld3_peach_v2.ko $G/vendor_dlkm/qca_cld3_peach_v2.ko)
WONDER=$(pick payload/kernel/wonder.ko $G/vendor_dlkm/wonder.ko)
SERVER=$(pick payload/system_ext/mosey_server $G/system_ext/bin/mosey_server)
LIB=$(pick payload/system_ext/libmosey_daemon_ffi.so $G/system_ext/lib64/libmosey_daemon_ffi.so)
MANIFEST=$(pick payload/system_ext/manifest_mosey.xml $G/system_ext/etc/vintf/manifest/manifest_mosey.xml)
FW=$(pick payload/firmware/peach $G/firmware/peach)
APKS=$(pick module-mosey-vivo/payload/priv-app/MoseyApp)
MODULE=$(pick module-airdrop)
MODDIR=/data/adb/modules/vivo_airdrop

command -v adb >/dev/null || die "adb is not installed"
command -v python3 >/dev/null || die "python3 is not installed"
if [ -z "${SERIAL:-}" ]; then
    SERIAL=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
    [ "$(printf '%s\n' "$SERIAL" | grep -c .)" = 1 ] || die "connect exactly one phone, or set SERIAL=..."
fi
dev() { adb -s "$SERIAL" shell "$@" | tr -d '\r'; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

preflight() {
    [ "$(dev getprop ro.product.model)" = "$EXPECTED_MODEL" ] || die "this package is only for the vivo X300 Ultra CN ($EXPECTED_MODEL)"
    [ "$(dev id -u)" = 0 ] || die "adb shell is not root yet; restore root with your own KernelSU workflow first"
    local k; k=$(dev uname -r)
    [ "$k" = "$EXPECTED_KERNEL" ] || die "kernel $k differs from $EXPECTED_KERNEL; the modules were checked against that kernel only"
    dev "test -x /data/adb/ksud && test -x /data/adb/ksu/bin/busybox" || die "KernelSU ksud/busybox not found"
    [ -n "$(dev pm path com.google.android.gms)" ] || die "Google Play services is not installed"
}

# Push a file unless the phone already has an identical copy.
push() {
    local src=$1 dst=$2
    [ "$(sha "$src")" = "$(dev "sha256sum $dst 2>/dev/null" | cut -d' ' -f1 || true)" ] || adb -s "$SERIAL" push "$src" "$dst" >/dev/null
}

# Push a directory plus a SHA256SUMS of it unless the phone's copy already verifies.
push_tree() {
    local src=$1 dst=$2 sums
    sums=$(mktemp)
    (cd "$src" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | while read -r f; do shasum -a 256 "$f"; done) > "$sums"
    if ! dev "cd $dst 2>/dev/null && sha256sum -cs SHA256SUMS && [ \$(grep -c . SHA256SUMS) = $(grep -c . "$sums") ]"; then
        dev "rm -rf $dst && mkdir -p $dst"
        adb -s "$SERIAL" push "$src/." "$dst/" >/dev/null
        adb -s "$SERIAL" push "$sums" "$dst/SHA256SUMS" >/dev/null
        dev "cd $dst && sha256sum -cs SHA256SUMS" || die "copy of $src on the phone does not verify"
    fi
    rm -f "$sums"
}

up() {
    preflight
    echo "== Copying files to $D"
    dev "mkdir -p $D"
    local sup_before; sup_before=$(dev "sha256sum $D/airdrop-start-server.sh 2>/dev/null" | cut -d' ' -f1 || true)
    for f in "$SHIM" "$QCA" "$WONDER" "$SERVER" "$ROOT"/scripts/device/airdrop-*.sh \
             "$ROOT/scripts/vivo-mosey-privapp-device.sh" "$ROOT/scripts/vivo-cn-google-device.sh"; do
        push "$f" "$D/$(basename "$f")"
    done
    dev "chmod 755 $D/*.sh $D/mosey_server"
    local stage; stage=$(mktemp -d)
    mkdir -p "$stage/lib64" "$stage/vintf"
    cp "$LIB" "$stage/lib64/"; cp "$MANIFEST" "$stage/vintf/"
    push_tree "$stage" "$D/payload"; rm -rf "$stage"
    push_tree "$FW" "$D/fw-peach"

    echo "== Mosey as a privileged app"
    if [ -z "$(dev pm path $MOSEY)" ]; then
        adb -s "$SERIAL" install-multiple -g "$APKS"/*.apk
    fi
    if ! dev "dumpsys package $MOSEY" | grep -q 'privateFlags=.*PRIVILEGED'; then
        python3 "$ROOT/scripts/vivo-mosey-privapp.py" --serial "$SERIAL" apply | tail -3
    fi
    dev "dumpsys package $MOSEY" | grep -q 'privateFlags=.*PRIVILEGED' || die "Mosey did not become a privileged app"

    echo "== Wi-Fi firmware with Passthru (read-only bind)"
    local fw_before; fw_before=$(dev "sh $D/airdrop-firmware.sh status" | cut -d' ' -f1)
    dev "sh $D/airdrop-firmware.sh apply" | grep -v '^Note:' || true

    echo "== Kernel modules"
    dev "grep -q '^wonder_shim ' /proc/modules || insmod $D/wonder_shim.ko"
    # The global driver imports wonder_shim, so the shim's line lists it as a user.
    if ! dev "grep -q '^wonder_shim .*qca_cld3_peach_v2' /proc/modules" || [ "$fw_before" != firmware_mount=owned ]; then
        # The CN firmware asserts on a Passthru vdev, so the driver must start on the global set.
        dev "grep -q '^wonder ' /proc/modules && rmmod wonder || true"
        dev "sh $D/airdrop-swap-wifi.sh"
        dev "grep -E '^(rmmod|insmod)=' $D/swap.log" | tr '\n' ' '; echo
    fi
    dev "grep -q '^wonder ' /proc/modules || insmod $D/wonder.ko"
    dev "test -e /sys/bus/platform/drivers/wonder/wonder" || die "wonder did not bind; see adb shell dmesg"
    dev "cmd wifi set-wifi-enabled enabled" >/dev/null
    for _ in $(seq 30); do dev "cmd wifi status" | grep -q 'Wifi is connected' && break; sleep 2; done
    dev "cmd wifi status" | grep -m1 'connected to' || dev "cmd wifi status" | head -1

    echo "== Mosey daemon"
    dev "sh $D/airdrop-userspace.sh apply" | grep -v '^NormalPerm' || true
    # A supervisor started from an older script keeps running old code; replace it.
    if [ "$sup_before" != "$(sha "$ROOT/scripts/device/airdrop-start-server.sh")" ]; then
        dev "sh $D/airdrop-start-server.sh stop"
    fi
    dev "nohup setsid sh $D/airdrop-start-server.sh start >/dev/null 2>&1 &"
    for _ in $(seq 20); do dev "service check $SERVICE" | grep -q ': found' && break; sleep 1; done
    dev "service check $SERVICE" | grep -q ': found' || die "mosey_server did not register; see $D/mosey_server.log"
    echo "$SERVICE registered"

    echo "== Mosey app"
    # NETWORK_FACTORY is a role permission; the CN Connectivity module needs it for mosey0.
    dev "pm grant $MOSEY android.permission.NETWORK_FACTORY"
    dev "cmd deviceidle whitelist +$MOSEY >/dev/null; am set-standby-bucket $MOSEY active"
    [ -n "$(dev pidof $MOSEY || true)" ] || dev "am startservice --user 0 -n $MOSEY/.ExternalSharingService >/dev/null"
    # Quick Share tile in the control center. The tile list is a saved setting, so this runs once.
    local tile=com.google.android.gms/.nearby.sharing.SharingTileService
    dev "settings get secure sysui_qs_tiles" | grep -qF "custom($tile)" || dev "cmd statusbar add-tile $tile" >/dev/null

    echo "== Autostart after reboots (KernelSU module vivo_airdrop)"
    dev "mkdir -p $D/module-vivo_airdrop"
    for f in "$MODULE"/*; do push "$f" "$D/module-vivo_airdrop/$(basename "$f")"; done
    dev "mkdir -p $MODDIR && cp $D/module-vivo_airdrop/* $MODDIR/ && chmod 755 $MODDIR/late-load.sh && rm -f $MODDIR/disable"
    echo "on: after a reboot, restoring root brings AirDrop up by itself (log: $D/autostart.log)"
    echo
    echo "Ready. On the Mac or iPhone set AirDrop to 'Everyone for 10 minutes', then share a file"
    echo "on the phone and pick Quick Share. To receive, open Quick Share > Receive and keep the screen on."
}

status() {
    echo "phone: $SERIAL  model $(dev getprop ro.product.model)  root uid=$(dev id -u)"
    [ "$(dev id -u)" = 0 ] || { echo "adb shell is not root"; return; }
    dev "sh $D/airdrop-firmware.sh status 2>/dev/null; sh $D/airdrop-userspace.sh status 2>/dev/null" || true
    echo "wifi driver: $(dev getprop vendor.wlan.driver.version)"
    dev "service check $SERVICE"
    dev "dumpsys package $MOSEY" | grep -E 'privateFlags|NETWORK_FACTORY: granted' | sed 's/^ *//' | head -2
    # adj 900 or more means Android cached Mosey and may freeze it; the supervisor wakes it.
    p=$(dev pidof $MOSEY || true)
    echo "mosey app pid: ${p:-none}${p:+ adj $(dev cat /proc/$p/oom_score_adj)}  $(dev "sh $D/airdrop-start-server.sh status" || true)"
    if dev "test -f $MODDIR/module.prop"; then
        dev "test -f $MODDIR/disable" && echo "autostart: off" || echo "autostart: on"
    else
        echo "autostart: not installed"
    fi
}

down() {
    [ "$(dev id -u)" = 0 ] || die "adb shell is not root"
    dev "sh $D/airdrop-start-server.sh stop" || true
    if dev "grep -q '^wonder_shim .*qca_cld3_peach_v2' /proc/modules"; then
        dev "sh $D/airdrop-restore-wifi.sh"
        dev "grep -E 'rmmod=|insmod=' $D/restore.log" | tr '\n' ' '; echo
    fi
    dev "grep -q '^wonder ' /proc/modules && rmmod wonder; grep -q '^wonder_shim ' /proc/modules && rmmod wonder_shim; true"
    dev "sh $D/airdrop-firmware.sh undo; sh $D/airdrop-userspace.sh undo" || true
    dev "test -d $MODDIR && touch $MODDIR/disable; true"
    echo "Removed, and autostart is off until the next 'up'. Mosey stays a privileged app and the"
    echo "SELinux rules stay until the next reboot."
}

case "${1:-up}" in
    up) up ;;
    status) status ;;
    down) down ;;
    *) die "usage: $0 [up|status|down]" ;;
esac
