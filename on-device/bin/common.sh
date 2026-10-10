#!/system/bin/sh
# vivo X300 Ultra (V2547A) China AirDrop support library for the KernelSU module.
#
# Sourced by the module's boot hooks and by bin/server.sh. When the caller is not
# in PID 1's mount namespace it re-execs the caller there, so every overlay or
# bind mount made below is visible to the whole system.
#
# Nothing here writes to or remounts a system partition: the new content lives on
# a private tmpfs ($RB, $FB), the overlay upper/work trees live on that tmpfs, and
# the two single-file binds read straight out of /data. A reboot drops all of it.

# ---- module identity and paths ------------------------------------------------
MODDIR=${MODDIR:-${0%/*}}
[ "$MODDIR" = "${0}" ] && MODDIR=$(pwd)
MODDIR=$(cd "$MODDIR" 2>/dev/null && pwd) || MODDIR=${MODDIR:-$(pwd)}
export MODDIR
M=$MODDIR
P=$M/payload
S=/data/adb/vivo-x300u-airdrop          # persistent state: logs, XML backup, guard
R=/data/local/tmp/airdrop               # runtime staging (same spot the adb flow used)
RB=/mnt/vivo-airdrop                    # tmpfs that holds the overlay upper/work trees
FB=/mnt/vivo-airdrop-fw                 # tmpfs that holds the Wi-Fi firmware image set
LOG=$S/airdrop.log
BB=/data/adb/ksu/bin/busybox
MODEL=V2547A

# ---- system targets -----------------------------------------------------------
SS_LIB=/system_ext/lib64
SS_VINTF=/system_ext/etc/vintf/manifest
PA_TARGET=/product/priv-app
PM_TARGET=/product/etc/permissions
CN_TARGET=/product/etc/sysconfig/cn_feature.xml
FW_TARGET=/vendor/firmware_mnt/image/peach
MOSEY=com.google.android.mosey

LIB=libmosey_daemon_ffi.so
VINTF=manifest_mosey.xml
APP_DIR=MoseyApp
PAPK_XML='privapp-permissions-mosey-vivo.xml mosey-hiddenapi-vivo.xml'
APKS='base.apk split_config.arm64_v8a.apk split_config.xxhdpi.apk split_config.en.apk'
CN_FEATURE=cn.google.services
CN_UPDATER=com.google.android.feature.services_updater
CN_DRIVER=/vendor_dlkm/lib/modules/qca_cld3_peach_v2.ko
# The global Wi-Fi image set the driver needs for the Passthru (wondertap) path.
# The CN set asserts on that path, so we refuse to load the global driver unless
# the firmware actually bound and reports this version.
FW_VERSION=WLAN.GNG.2.0-01536
KSUSD=/data/adb/ksud
# Per-kernel-boot identity. A *real* boot changes it (overlays are gone, so we must
# refresh again); a `ksud soft-reboot` (userspace reboot) does not (so we refresh once).
BOOTID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)

mkdir -p "$S" 2>/dev/null
chmod 0700 "$S" 2>/dev/null
umask 077

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >>"$LOG" 2>/dev/null
    printf '%s\n' "$*"
}
die() { log "ERROR: $*"; exit 1; }

# ---- run under Android's shell, in PID 1's mount namespace ---------------------
# KernelSU runs stage scripts in BusyBox ash, whose applets differ from Android's
# toybox (e.g. `stat -f -c %T` prints UNKNOWN). Always re-exec under /system/bin/sh,
# entering PID 1's namespace when needed. AIRDROP_SH breaks the re-exec loop.
if [ "${AIRDROP_SH:-}" != 1 ]; then
    export AIRDROP_SH=1
    if [ "$(readlink /proc/self/ns/mnt 2>/dev/null)" != "$(readlink /proc/1/ns/mnt 2>/dev/null)" ]; then
        [ -x "$BB" ] || { printf 'airdrop: mount namespace differs and %s is missing\n' "$BB" >&2; exit 1; }
        exec "$BB" nsenter -t 1 -m /system/bin/sh "$0" "$@"
    fi
    exec /system/bin/sh "$0" "$@"
fi

# ---- device guard -------------------------------------------------------------
guard() {
    [ "$(getprop ro.product.model 2>/dev/null)" = "$MODEL" ] || {
        log "skip: model $(getprop ro.product.model) is not $MODEL"; return 1; }
    [ "$(getprop ro.build.version.sdk 2>/dev/null)" = 36 ] || {
        log "skip: API $(getprop ro.build.version.sdk) is not 36"; return 1; }
    return 0
}

# ---- boot loop guard ----------------------------------------------------------
GUARD_FILE=$S/bootcount
GUARD_LAST=$S/bootcount.bootid
guard_boot() {
    mkdir -p "$S" 2>/dev/null
    # Count at most once per kernel boot. A `ksud soft-reboot` re-runs this stage
    # without changing boot_id and must not look like another boot.
    [ "$(cat "$GUARD_LAST" 2>/dev/null)" = "$BOOTID" ] && return 0
    echo "$BOOTID" > "$GUARD_LAST"
    gn=0; [ -f "$GUARD_FILE" ] && gn=$(cat "$GUARD_FILE" 2>/dev/null)
    case "$gn" in ''|*[!0-9]*) gn=0 ;; esac
    gn=$((gn + 1))
    echo "$gn" > "$GUARD_FILE"
    if [ "$gn" -gt 3 ]; then
        log "boot loop guard: $gn boots without Android finishing; disabling the module"
        : > "$M/disable"
        return 1
    fi
    return 0
}
guard_ok() { echo 0 > "$GUARD_FILE" 2>/dev/null; }

# ---- mount helpers ------------------------------------------------------------
top_mount() { # $1 path -> "<fstype> <options>" or empty
    awk -v t="$1" '
        $5 == t { for (i = 7; i <= NF; i++) if ($i == "-") { line = $(i+1) " " $(i+3) } }
        END { if (line != "") print line }' /proc/self/mountinfo
}
mount_at() { awk -v t="$1" '$5 == t { f = 1 } END { exit f ? 0 : 1 }' /proc/self/mountinfo; }
label_of() { ls -Zd "$1" 2>/dev/null | awk '{print $1}'; }

mount_state() { # $1 target $2 upper key -> owned|foreign|absent
    mi=$(top_mount "$1")
    [ -n "$mi" ] || { echo absent; return; }
    case "$mi" in
        "overlay "*"upperdir=$RB/upper/$2,"*) echo owned ;;
        *) echo foreign ;;
    esac
}
tmpfs_state() {
    mi=$(top_mount "$RB")
    [ -n "$mi" ] || { echo absent; return; }
    case "$mi" in tmpfs\ *) echo owned ;; *) echo foreign ;; esac
}
fw_state() {
    mount_at "$FW_TARGET" || { echo absent; return; }
    if [ "$(stat -c '%d:%i' "$FW_TARGET/amss20.bin" 2>/dev/null)" = "$(stat -c '%d:%i' "$FB/peach/amss20.bin" 2>/dev/null)" ]; then
        echo owned
    else
        echo foreign
    fi
}
cn_state() {
    mount_at "$CN_TARGET" || { echo absent; return; }
    if [ "$(stat -c '%d:%i' "$CN_TARGET" 2>/dev/null)" = "$(stat -c '%d:%i' "$S/cn_feature.disabled.xml" 2>/dev/null)" ]; then
        echo owned
    else
        echo foreign
    fi
}

overlay_root() {
    mkdir -p "$RB"
    case "$(tmpfs_state)" in
        owned) ;;
        foreign) die "unexpected mount at $RB" ;;
        absent) mount -t tmpfs -o mode=0755 tmpfs "$RB" || die "cannot mount tmpfs at $RB" ;;
    esac
}

# ---- payload integrity --------------------------------------------------------
payload_verify() { # optional args: relative paths; no args = everything
    [ -f "$P/SHA256SUMS" ] || { log "payload: checksum list missing"; return 1; }
    if [ $# -eq 0 ]; then
        (cd "$P" && sha256sum -cs SHA256SUMS) >/dev/null 2>&1 || { log "payload: checksum mismatch"; return 1; }
        return 0
    fi
    for pv_r in "$@"; do
        pv_want=$(awk -v p="$pv_r" '$2 == p { print $1 }' "$P/SHA256SUMS")
        [ -n "$pv_want" ] || { log "payload: $pv_r not in checksum list"; return 1; }
        pv_got=$(sha256sum "$P/$pv_r" | awk '{print $1}')
        [ "$pv_want" = "$pv_got" ] || { log "payload: checksum mismatch for $pv_r"; return 1; }
    done
    return 0
}

# ---- read-only overlays: /system_ext (lib + VINTF) ----------------------------
apply_systemext() {
    ss_lib=$(mount_state "$SS_LIB" sysext-lib)
    ss_vin=$(mount_state "$SS_VINTF" sysext-vintf)
    if [ "$ss_lib" = owned ] && [ "$ss_vin" = owned ]; then
        log "system_ext: overlays already mounted"; return 0
    fi
    if [ "$ss_lib" = foreign ] || [ "$ss_vin" = foreign ]; then
        log "system_ext: a foreign mount covers a target, skipping"; return 1
    fi
    if [ "$ss_lib" = owned ] || [ "$ss_vin" = owned ]; then
        undo_systemext
    fi
    overlay_root
    mkdir -p "$RB/upper/sysext-lib" "$RB/upper/sysext-vintf" \
             "$RB/work/sysext-lib" "$RB/work/sysext-vintf"
    cp -f "$P/system_ext/$LIB"   "$RB/upper/sysext-lib/$LIB"     || die "system_ext: stage $LIB"
    cp -f "$P/system_ext/$VINTF" "$RB/upper/sysext-vintf/$VINTF" || die "system_ext: stage $VINTF"
    chown -R 0:0 "$RB/upper/sysext-lib" "$RB/upper/sysext-vintf" "$RB/work/sysext-lib" "$RB/work/sysext-vintf"
    chmod 0755 "$RB/upper/sysext-lib" "$RB/upper/sysext-vintf"
    chmod 0644 "$RB/upper/sysext-lib/$LIB" "$RB/upper/sysext-vintf/$VINTF"
    chcon -R u:object_r:system_lib_file:s0 "$RB/upper/sysext-lib" "$RB/work/sysext-lib"
    chcon -R u:object_r:system_file:s0     "$RB/upper/sysext-vintf" "$RB/work/sysext-vintf"
    mount -t overlay overlay -o "ro,lowerdir=$SS_LIB,upperdir=$RB/upper/sysext-lib,workdir=$RB/work/sysext-lib" "$SS_LIB" \
        || die "system_ext: overlay on $SS_LIB failed"
    mount -t overlay overlay -o "ro,lowerdir=$SS_VINTF,upperdir=$RB/upper/sysext-vintf,workdir=$RB/work/sysext-vintf" "$SS_VINTF" \
        || { umount "$SS_LIB" 2>/dev/null; die "system_ext: overlay on $SS_VINTF failed"; }
    [ -f "$SS_LIB/$LIB" ] && [ -f "$SS_VINTF/$VINTF" ] || die "system_ext: files not visible after mounting"
    log "system_ext: read-only overlays mounted on $SS_LIB and $SS_VINTF"
}

# ---- read-only overlays: /product (Mosey priv-app + allowlists) ---------------
apply_product() {
    pa=$(mount_state "$PA_TARGET" priv-app)
    pm=$(mount_state "$PM_TARGET" permissions)
    if [ "$pa" = owned ] && [ "$pm" = owned ]; then
        log "product: overlays already mounted"; return 0
    fi
    if [ "$pa" = foreign ] || [ "$pm" = foreign ]; then
        log "product: a foreign mount covers a target, skipping"; return 1
    fi
    if [ "$pa" = owned ] || [ "$pm" = owned ]; then
        undo_product
    fi
    [ "$(stat -f -c '%T' "$PA_TARGET" 2>/dev/null)" = erofs ] || die "product: $PA_TARGET is not on EROFS"
    [ "$(stat -f -c '%T' "$PM_TARGET" 2>/dev/null)" = erofs ] || die "product: $PM_TARGET is not on EROFS"
    [ ! -e "$PA_TARGET/$APP_DIR" ] || die "product: $PA_TARGET already contains $APP_DIR"
    for xmlf in $PAPK_XML; do
        [ ! -e "$PM_TARGET/$xmlf" ] || die "product: $PM_TARGET already contains $xmlf"
    done
    overlay_root
    mkdir -p "$RB/upper/priv-app/$APP_DIR" "$RB/upper/permissions" \
             "$RB/work/priv-app" "$RB/work/permissions"
    for apkf in $APKS; do
        cp -f "$P/priv-app/$APP_DIR/$apkf" "$RB/upper/priv-app/$APP_DIR/$apkf" || die "product: stage $apkf"
    done
    for xmlf in $PAPK_XML; do
        cp -f "$P/permissions/$xmlf" "$RB/upper/permissions/$xmlf" || die "product: stage $xmlf"
    done
    chown -R 0:0 "$RB/upper/priv-app" "$RB/upper/permissions" "$RB/work/priv-app" "$RB/work/permissions"
    chmod 0755 "$RB/upper/priv-app" "$RB/upper/priv-app/$APP_DIR" "$RB/upper/permissions"
    chmod 0644 "$RB/upper/priv-app/$APP_DIR"/*.apk "$RB/upper/permissions"/*.xml
    chcon -R u:object_r:system_file:s0 "$RB/upper/priv-app" "$RB/upper/permissions" \
                                     "$RB/work/priv-app" "$RB/work/permissions"
    mount -t overlay overlay -o "ro,lowerdir=$PM_TARGET,upperdir=$RB/upper/permissions,workdir=$RB/work/permissions" "$PM_TARGET" \
        || die "product: overlay on $PM_TARGET failed"
    mount -t overlay overlay -o "ro,lowerdir=$PA_TARGET,upperdir=$RB/upper/priv-app,workdir=$RB/work/priv-app" "$PA_TARGET" \
        || { umount "$PM_TARGET" 2>/dev/null; die "product: overlay on $PA_TARGET failed"; }
    [ -f "$PA_TARGET/$APP_DIR/base.apk" ] && [ -f "$PM_TARGET/privapp-permissions-mosey-vivo.xml" ] &&
        [ -f "$PM_TARGET/mosey-hiddenapi-vivo.xml" ] && [ -d "$PA_TARGET/GmsCore" ] \
        || die "product: overlay content not visible after mounting"
    [ "$(label_of "$PA_TARGET/$APP_DIR/base.apk")" = "u:object_r:system_file:s0" ] \
        || log "product: warning: unexpected SELinux label on staged APK"
    log "product: read-only overlays mounted on $PA_TARGET and $PM_TARGET"
}

# ---- single-file bind: disable the CN Quick Share feature ---------------------
apply_cn_feature() {
    [ -f "$CN_TARGET" ] || { log "cn_feature: $CN_TARGET is missing, skipping"; return 1; }
    case "$(cn_state)" in
        owned) log "cn_feature: bind already active"; return 0 ;;
        foreign) log "cn_feature: another mount covers $CN_TARGET, skipping"; return 1 ;;
    esac
    if grep -q "<unavailable-feature[^>]*name=\"$CN_FEATURE\"" "$CN_TARGET"; then
        log "cn_feature: already unavailable in the ROM, nothing to do"; return 0
    fi
    cn_n=$(grep -c "<feature[^>]*name=\"$CN_FEATURE\"" "$CN_TARGET")
    [ "$cn_n" = 1 ] || { log "cn_feature: expected exactly one $CN_FEATURE element, found $cn_n, skipping"; return 1; }
    grep -q "$CN_UPDATER" "$CN_TARGET" || { log "cn_feature: $CN_UPDATER missing, skipping"; return 1; }
    [ "$(stat -f -c '%T' "$CN_TARGET" 2>/dev/null)" = erofs ] || { log "cn_feature: target is not on EROFS, skipping"; return 1; }
    mkdir -p "$S"
    [ -e "$S/cn_feature.original.xml" ] || cp -f "$CN_TARGET" "$S/cn_feature.original.xml"
    # Drop the <feature name="cn.google.services"/> element so Quick Share is not
    # gated behind the CN feature. The element is self-closing on this ROM; if it
    # ever is not, fall back to marking it <unavailable-feature> instead.
    if grep -Eq "<feature[^>]*name=\"$CN_FEATURE\"[^>]*/>" "$CN_TARGET"; then
        sed -E "s|<feature[^>]*name=\"$CN_FEATURE\"[^>]*/>||" "$CN_TARGET" > "$S/cn_feature.disabled.xml"
    else
        sed -E "s|<feature([^>]*name=\"$CN_FEATURE\")|<unavailable-feature\1|" "$CN_TARGET" > "$S/cn_feature.disabled.xml"
    fi
    [ -s "$S/cn_feature.disabled.xml" ] || { log "cn_feature: patched XML is empty"; return 1; }
    grep -q "<feature[^>]*name=\"$CN_FEATURE\"" "$S/cn_feature.disabled.xml" \
        && { log "cn_feature: $CN_FEATURE still present after the patch"; return 1; }
    grep -q "$CN_UPDATER" "$S/cn_feature.disabled.xml" || { log "cn_feature: $CN_UPDATER was lost"; return 1; }
    grep -q "</config>" "$S/cn_feature.disabled.xml" || { log "cn_feature: patched XML looks truncated"; return 1; }
    chown 0:0 "$S/cn_feature.disabled.xml"
    chmod 0644 "$S/cn_feature.disabled.xml"
    chcon u:object_r:system_file:s0 "$S/cn_feature.disabled.xml"
    mount -o bind "$S/cn_feature.disabled.xml" "$CN_TARGET" || { log "cn_feature: bind mount failed"; return 1; }
    log "cn_feature: $CN_FEATURE removed through a read-only bind mount"
}

undo_cn_feature() {
    case "$(cn_state)" in
        owned) umount "$CN_TARGET" 2>/dev/null || umount -l "$CN_TARGET" 2>/dev/null; log "cn_feature: bind removed" ;;
    esac
}

# ---- the three userspace overlays in one step ---------------------------------
apply_userspace() {
    apply_systemext || return 1
    apply_product || return 1
    apply_cn_feature || log "userspace: the CN feature bind was skipped"
    return 0
}

# ---- late-load bookkeeping ----------------------------------------------------
# The device only gets root after Android has booted, so the overlays reach the
# ROM too late for PackageManager/servicemanager to see them. We mount them from
# the late-load stage and then ask for one `ksud soft-reboot`, whose emulated boot
# re-runs the post-fs-data stage (framework stopped -> PM rescans) and later the
# boot-completed stage, which is where the Wi-Fi half runs.
clean_old_markers() {
    for cf in "$S"/refreshed.* "$S"/post-fs-data.*; do
        [ -e "$cf" ] || continue
        case "$cf" in *".$BOOTID") ;; *) rm -f "$cf" ;; esac
    done
}
post_fs_data_mark() { : > "$S/post-fs-data.$BOOTID"; }
post_fs_data_done() { [ -f "$S/post-fs-data.$BOOTID" ]; }

# Android has rescanned and installed the app from the overlay priv-app.
promoted() { pm path "$MOSEY" 2>/dev/null | grep -q "/product/priv-app/$APP_DIR"; }

# Ask for exactly one Android refresh per kernel boot, and never when Android has
# already picked up the overlay. This is keyed on the real symptom (the app is
# live) as well as the marker, so extra `late-load` / `soft-reboot` passes restart
# nothing.
refresh_once() {
    if [ -f "$S/refreshed.$BOOTID" ] || promoted; then
        : > "$S/refreshed.$BOOTID"
        log "refresh: Android already sees the privileged app, not refreshing again"
        return 0
    fi
    [ -x "$KSUSD" ] || { log "refresh: $KSUSD is missing, cannot refresh Android"; return 1; }
    : > "$S/refreshed.$BOOTID"
    log "refresh: asking Android to re-read the overlays (ksud soft-reboot)"
    "$KSUSD" soft-reboot
}

wait_boot() { # bounded wait until Android reports boot complete
    wb=0
    while [ "$wb" -lt 60 ]; do
        [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] && return 0
        sleep 2; wb=$((wb + 1))
    done
    return 1
}

# ---- global Wi-Fi firmware over the CN set ------------------------------------
fw_version_ok() {
    grep -a -q "QC_IMAGE_VERSION_STRING=$FW_VERSION" "$FW_TARGET/amss20.bin" 2>/dev/null
}
apply_firmware() {
    case "$(fw_state)" in
        owned)
            if fw_version_ok; then
                log "firmware: global image set already bound"; return 0
            fi
            log "firmware: the active bind is not the expected global set; replacing it"
            umount "$FW_TARGET" 2>/dev/null || umount -l "$FW_TARGET" 2>/dev/null
            ;;
        foreign) log "firmware: another mount covers $FW_TARGET, skipping"; return 1 ;;
    esac
    [ -d "$P/firmware/peach" ] || { log "firmware: payload is missing"; return 1; }
    mkdir -p "$FB"
    case "$(top_mount "$FB")" in
        '') mount -t tmpfs -o mode=0755 tmpfs "$FB" || { log "firmware: tmpfs failed"; return 1; } ;;
        tmpfs\ *) ;;
        *) log "firmware: unexpected mount at $FB, skipping"; return 1 ;;
    esac
    rm -rf "$FB/peach"
    mkdir -p "$FB/peach"
    for f in "$P"/firmware/peach/*; do
        cp -f "$f" "$FB/peach/${f##*/}" || { log "firmware: copy ${f##*/} failed"; return 1; }
    done
    chown -R 1000:1000 "$FB/peach"
    chmod 0550 "$FB/peach"
    chmod 0440 "$FB"/peach/*
    chcon -R u:object_r:firmware_file:s0 "$FB/peach"
    mount --bind "$FB/peach" "$FW_TARGET" || { log "firmware: bind mount failed"; return 1; }
    mount -o remount,bind,ro "$FW_TARGET" || { umount "$FW_TARGET" 2>/dev/null; log "firmware: read-only remount failed"; return 1; }
    if ! fw_version_ok; then
        umount "$FW_TARGET" 2>/dev/null || umount -l "$FW_TARGET" 2>/dev/null
        log "firmware: the bound image is not the expected global set; leaving the CN one in place"
        return 1
    fi
    log "firmware: global Wi-Fi image set ($FW_VERSION) bound read-only over $FW_TARGET"
}

undo_firmware() {
    case "$(fw_state)" in
        owned) umount "$FW_TARGET" 2>/dev/null || umount -l "$FW_TARGET" 2>/dev/null ;;
    esac
    case "$(top_mount "$FB")" in
        tmpfs\ *) umount "$FB" 2>/dev/null || umount -l "$FB" 2>/dev/null ;;
    esac
}

# ---- kernel modules -----------------------------------------------------------
load_ko() { # $1 .ko path, $2 module name
    grep -q "^$2 " /proc/modules 2>/dev/null && return 0
    insmod "$1" 2>>"$LOG" && { log "kernel: loaded $2"; return 0; }
    mkdir -p "$R"
    cp -f "$1" "$R/${1##*/}" && chmod 0644 "$R/${1##*/}"
    insmod "$R/${1##*/}" 2>>"$LOG" && { log "kernel: loaded $2 (from $R)"; return 0; }
    log "kernel: insmod $2 failed; check dmesg and the module vermagic"
    return 1
}

swap_wifi() {
    grep -q '^wonder_shim ' /proc/modules || { log "wifi: wonder_shim is not loaded, skipping swap"; return 1; }
    cmd wifi set-wifi-enabled disabled 2>/dev/null
    wi=0; while [ "$wi" -lt 20 ]; do
        cmd wifi status 2>/dev/null | grep -q 'Wifi is disabled' && break
        sleep 1; wi=$((wi + 1))
    done
    sleep 2
    rmmod qca_cld3_peach_v2 2>>"$LOG" || log "wifi: rmmod of the CN driver failed"
    sleep 1
    load_ko "$P/kernel/qca_cld3_peach_v2.ko" qca_cld3_peach_v2 || return 1
    wi=0; while [ "$wi" -lt 30 ]; do
        ip link show wlan0 >/dev/null 2>&1 && break
        sleep 1; wi=$((wi + 1))
    done
    ip link show wlan0 >/dev/null 2>&1 || { log "wifi: wlan0 did not come back"; return 1; }
    log "wifi: global driver loaded"
    return 0
}

restore_wifi() {
    cmd wifi set-wifi-enabled disabled 2>/dev/null
    sleep 3
    grep -q '^wonder ' /proc/modules 2>/dev/null && rmmod wonder 2>>"$LOG"
    rmmod qca_cld3_peach_v2 2>>"$LOG"
    undo_firmware
    insmod "$CN_DRIVER" 2>>"$LOG" || log "wifi: insmod of the CN driver failed"
    wi=0; while [ "$wi" -lt 30 ]; do
        ip link show wlan0 >/dev/null 2>&1 && break
        sleep 1; wi=$((wi + 1))
    done
    cmd wifi set-wifi-enabled enabled 2>/dev/null
    sleep 5
    log "wifi: the phone's own driver is back"
}

# ---- Mosey app ----------------------------------------------------------------
# Runtime (dangerous) permissions Mosey requests, plus the NETWORK_FACTORY role
# permission the CN Connectivity module needs for mosey0. Mirrors the original
# adb flow's RUNTIME_PERMS + `pm grant NETWORK_FACTORY`.
RUNTIME_PERMS='android.permission.ACCESS_FINE_LOCATION android.permission.ACCESS_COARSE_LOCATION android.permission.ACCESS_BACKGROUND_LOCATION android.permission.NEARBY_WIFI_DEVICES android.permission.BLUETOOTH_SCAN android.permission.BLUETOOTH_ADVERTISE android.permission.NETWORK_FACTORY'
grant_app() {
    for gp in $RUNTIME_PERMS; do
        pm grant "$MOSEY" "$gp" >/dev/null 2>&1
    done
    cmd deviceidle whitelist "+$MOSEY" >/dev/null 2>&1
    am set-standby-bucket "$MOSEY" active >/dev/null 2>&1
    if ! pidof "$MOSEY" >/dev/null 2>&1; then
        am startservice --user 0 -n "$MOSEY/.ExternalSharingService" >/dev/null 2>&1
    fi
    log "mosey: runtime permissions, whitelist and service applied"
}

# ---- daemon supervisor --------------------------------------------------------
SERVER_PID=$S/server.pid
server_stop() {
    if [ -f "$SERVER_PID" ]; then
        kill "$(cat "$SERVER_PID" 2>/dev/null)" >/dev/null 2>&1
        rm -f "$SERVER_PID"
    fi
    pkill -f '[b]in/server.sh' >/dev/null 2>&1
    pkill -x mosey_server >/dev/null 2>&1
}
server_start() {
    if [ -f "$SERVER_PID" ] && kill -0 "$(cat "$SERVER_PID" 2>/dev/null)" >/dev/null 2>&1; then
        log "mosey: daemon supervisor already running"
        return 0
    fi
    mkdir -p "$R"
    [ -x "$R/mosey_server" ] || { cp -f "$P/system_ext/mosey_server" "$R/mosey_server" && chmod 0755 "$R/mosey_server"; }
    nohup setsid /system/bin/sh "$M/bin/server.sh" >/dev/null 2>&1 &
    log "mosey: daemon supervisor started"
}

# ---- full bring-up / teardown -------------------------------------------------
bringup() {
    # Never load the global Wi-Fi driver unless the global firmware is really bound:
    # the CN firmware asserts on the Passthru (wondertap) vdev and vivo reboots the
    # phone. If it is not bound, drop back to the phone's own driver and stop.
    if ! apply_firmware; then
        log "bringup: firmware step failed; refusing to load the global Wi-Fi driver"
        if grep -q '^wonder_shim .*qca_cld3_peach_v2' /proc/modules 2>/dev/null; then
            log "bringup: global driver is up without the global firmware; restoring the CN driver"
            restore_wifi
        fi
        grant_app
        return 1
    fi
    load_ko "$P/kernel/wonder_shim.ko" wonder_shim || true
    if grep -q '^wonder_shim .*qca_cld3_peach_v2' /proc/modules 2>/dev/null; then
        log "bringup: the global Wi-Fi driver is already loaded"
    else
        swap_wifi || log "bringup: Wi-Fi driver swap failed"
    fi
    load_ko "$P/kernel/wonder.ko" wonder || log "bringup: wonder did not load"
    [ -e /sys/bus/platform/drivers/wonder/wonder ] || log "bringup: warning: wonder did not bind"
    cmd wifi set-wifi-enabled enabled 2>/dev/null
    wi=0; while [ "$wi" -lt 30 ]; do
        cmd wifi status 2>/dev/null | grep -q 'Wifi is connected' && break
        sleep 2; wi=$((wi + 1))
    done
    grant_app
    log "bringup: done"
}

down() {
    server_stop
    if grep -q '^wonder_shim .*qca_cld3_peach_v2' /proc/modules 2>/dev/null; then
        restore_wifi
    fi
    grep -q '^wonder ' /proc/modules 2>/dev/null && rmmod wonder 2>>"$LOG"
    grep -q '^wonder_shim ' /proc/modules 2>/dev/null && rmmod wonder_shim 2>>"$LOG"
    undo_firmware
    undo_product
    undo_systemext
    undo_cn_feature
    log "teardown: kernel modules unloaded and overlays removed"
}

undo_product() {
    [ "$(mount_state "$PA_TARGET" priv-app)" = owned ] && { umount "$PA_TARGET" 2>/dev/null || umount -l "$PA_TARGET" 2>/dev/null; }
    [ "$(mount_state "$PM_TARGET" permissions)" = owned ] && { umount "$PM_TARGET" 2>/dev/null || umount -l "$PM_TARGET" 2>/dev/null; }
    true
}

undo_systemext() {
    [ "$(mount_state "$SS_LIB" sysext-lib)" = owned ] && { umount "$SS_LIB" 2>/dev/null || umount -l "$SS_LIB" 2>/dev/null; }
    [ "$(mount_state "$SS_VINTF" sysext-vintf)" = owned ] && { umount "$SS_VINTF" 2>/dev/null || umount -l "$SS_VINTF" 2>/dev/null; }
    true
}

status() {
    echo "model=$(getprop ro.product.model)  kernel=$(uname -r)  root_uid=$(id -u)"
    echo "boot_id=$BOOTID  post_fs_data_done=$(post_fs_data_done && echo yes || echo no)  refresh_requested=$([ -f "$S/refreshed.$BOOTID" ] && echo yes || echo no)"
    echo "product_overlay=$(mount_state "$PA_TARGET" priv-app)"
    echo "permissions_overlay=$(mount_state "$PM_TARGET" permissions)"
    echo "system_ext_lib=$(mount_state "$SS_LIB" sysext-lib)"
    echo "system_ext_vintf=$(mount_state "$SS_VINTF" sysext-vintf)"
    echo "cn_feature_bind=$(cn_state)"
    echo "firmware_bind=$(fw_state)"
    echo "modules=$(grep -oE '^(wonder_shim|wonder|qca_cld3_peach_v2) ' /proc/modules 2>/dev/null | tr -d '\n')"
    echo "wifi_driver=$(getprop vendor.wlan.driver.version)"
    echo "mosey_server=$(pidof mosey_server 2>/dev/null || echo none)"
    echo "mosey_app=$(pidof "$MOSEY" 2>/dev/null || echo none)"
}
