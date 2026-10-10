#!/system/bin/sh
# Bring the AirDrop stack up on the phone itself, without a computer. The vivo_airdrop
# KernelSU module starts this from late-load.sh each time root is restored after a reboot;
# it is also safe to run by hand. It needs the files that scripts/airdrop.sh left on the
# phone: /data/local/tmp/airdrop, the Mosey payload in /data/local/vivo-mosey-privapp and
# the CN flag state in /data/local/vivo-cn-google. Nothing is written to a partition and
# nothing is remounted read-write.
D=/data/local/tmp/airdrop
BB=/data/adb/ksu/bin/busybox
KSUD=/data/adb/ksud
LOG=$D/autostart.log
PIDFILE=/dev/vivo-airdrop-autostart.pid
EXPECTED_KERNEL=6.12.58-android16-6-g650e74cc80ec-abogki503021821-4k
MOSEY=com.google.android.mosey
SERVICE=com.google.android.moseyservice.IMoseyService/default
TILE=com.google.android.gms/.nearby.sharing.SharingTileService
RUNTIME_PERMS='ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION NEARBY_WIFI_DEVICES BLUETOOTH_SCAN BLUETOOTH_ADVERTISE'

if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
    exec "$BB" nsenter -t 1 -m /system/bin/sh "$0" "$@"
fi
exec >>$LOG 2>&1
# When root is restored over adb this runs inside adbd's cgroup, which init kills when the
# USB configuration changes. Leave it; the supervisor started below inherits the root cgroup.
echo $$ > /sys/fs/cgroup/cgroup.procs || echo "warning: still in cgroup $(grep ^0:: /proc/$$/cgroup)"
log() { echo "$(date '+%F %T') $*"; }
fail() { log "STOP: $*"; rm -f $PIDFILE; exit 1; }
if [ -f $PIDFILE ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
    log "another run ($(cat $PIDFILE)) is active; exiting"
    exit 0
fi
echo $$ > $PIDFILE
privileged() { dumpsys package $MOSEY | grep -q 'privateFlags=.*PRIVILEGED'; }

log "start"
[ "$(id -u)" = 0 ] || fail "not root"
[ "$(getprop ro.product.model)" = V2547A ] || fail "not a vivo V2547A"
[ "$(uname -r)" = "$EXPECTED_KERNEL" ] || fail "kernel $(uname -r) is not the one the modules were checked against"
for f in wonder_shim.ko qca_cld3_peach_v2.ko wonder.ko mosey_server airdrop-firmware.sh airdrop-swap-wifi.sh \
         airdrop-restore-wifi.sh airdrop-userspace.sh airdrop-start-server.sh vivo-mosey-privapp-device.sh; do
    [ -f $D/$f ] || fail "missing $D/$f; run airdrop.sh up from a computer once"
done
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 5

# 1. Mosey as a privileged app. PackageManager only rescans /product when the framework
#    restarts, so this needs one ksud soft-reboot after each phone reboot.
if ! privileged; then
    S=/data/local/vivo-cn-google
    orig=$(ls $S/cn_feature.original.*.xml 2>/dev/null | head -1)
    if [ -n "$orig" ] && [ -f $S/cn_feature.disabled.xml ] && [ -f $D/vivo-cn-google-device.sh ]; then
        sha=${orig##*/cn_feature.original.}; sha=${sha%.xml}
        cp $S/cn_feature.disabled.xml /data/local/tmp/vivo-cn-google-input.xml
        sh $D/vivo-cn-google-device.sh apply "$sha" /data/local/tmp/vivo-cn-google-input.xml || log "CN flag bind failed; continuing"
    fi
    sh $D/vivo-mosey-privapp-device.sh apply || fail "Mosey overlays failed"
    old=$(pidof system_server)
    log "soft-reboot so PackageManager rescans /product"
    $KSUD soft-reboot
    seen=""; n=0; ok=0
    while [ $n -lt 60 ]; do
        sleep 3; n=$((n + 1))
        pid=$(pidof system_server)
        if [ -n "$pid" ] && [ "$pid" != "$old" ]; then
            case " $seen " in *" $pid "*) ;; *) seen="$seen $pid" ;; esac
        fi
        if [ $(echo $seen | wc -w) -ge 3 ]; then
            log "system_server restarted 3 times; removing the Mosey overlays"
            sh $D/vivo-mosey-privapp-device.sh restore
            $KSUD soft-reboot
            fail "system_server crash loop"
        fi
        if [ -n "$pid" ] && [ "$pid" != "$old" ] && [ "$(getprop sys.boot_completed)" = 1 ] && privileged; then
            ok=1; break
        fi
    done
    [ $ok = 1 ] || fail "Mosey did not become privileged after the soft-reboot"
    for p in $RUNTIME_PERMS; do pm grant $MOSEY android.permission.$p; done
    cmd package unstop --user 0 $MOSEY
    log "Mosey is a privileged app"
fi

# 2. Global Wi-Fi firmware first: the CN firmware asserts on a Passthru vdev and vivo then
#    reboots the phone, so the driver must never start Passthru on it.
sh $D/airdrop-firmware.sh apply | grep -v '^Note:'
[ "$(sh $D/airdrop-firmware.sh status | cut -d' ' -f1)" = firmware_mount=owned ] || fail "global Wi-Fi firmware not shown; leaving the Wi-Fi driver alone"

# 3. Kernel modules.
grep -q '^wonder_shim ' /proc/modules || insmod $D/wonder_shim.ko || fail "wonder_shim did not load"
if ! grep -q '^wonder_shim .*qca_cld3_peach_v2' /proc/modules; then
    grep -q '^wonder ' /proc/modules && rmmod wonder
    sh $D/airdrop-swap-wifi.sh
    if ! grep -q '^wonder_shim .*qca_cld3_peach_v2' /proc/modules; then
        log "global Wi-Fi driver did not load; putting the CN driver back"
        sh $D/airdrop-restore-wifi.sh
        fail "Wi-Fi driver swap failed; see $D/swap.log"
    fi
fi
grep -q '^wonder ' /proc/modules || insmod $D/wonder.ko
[ -e /sys/bus/platform/drivers/wonder/wonder ] || fail "wonder did not bind"
cmd wifi set-wifi-enabled enabled

# 4. Daemon, VINTF and SELinux, then the supervisor that keeps mosey_server and Mosey alive.
sh $D/airdrop-userspace.sh apply | grep -v '^NormalPerm'
pm grant $MOSEY android.permission.NETWORK_FACTORY
cmd deviceidle whitelist +$MOSEY >/dev/null
am set-standby-bucket $MOSEY active
setsid sh $D/airdrop-start-server.sh start </dev/null >/dev/null 2>&1 &
n=0; until service check $SERVICE | grep -q ': found' || [ $n -ge 30 ]; do sleep 1; n=$((n + 1)); done
service check $SERVICE | grep -q ': found' || fail "mosey_server did not register; see $D/mosey_server.log"
settings get secure sysui_qs_tiles | grep -qF "custom($TILE)" || cmd statusbar add-tile $TILE
log "AirDrop ready"
rm -f $PIDFILE
