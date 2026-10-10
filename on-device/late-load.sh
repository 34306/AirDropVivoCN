#!/system/bin/sh
# Late-load stage. This device gets root only after Android has booted (locked
# bootloader), so this stage is where the overlays are put in place. Android has
# already read /product, /system_ext and the sysconfig XML, so right after mounting
# we ask for one `ksud soft-reboot`; its emulated boot re-runs the post-fs-data
# stage with the framework stopped (PackageManager rescans, servicemanager re-reads
# the VINTF fragment, SystemConfig re-reads cn_feature.xml). The Wi-Fi and app half
# then runs from boot-completed.sh, on that refreshed boot.
d=${0%/*}
[ "$d" = "$0" ] && d=$(pwd)
export MODDIR=$d
. "$MODDIR/bin/common.sh"

guard || exit 0
clean_old_markers
wait_boot || log "late-load: Android has not reported boot_completed yet, continuing"

payload_verify \
    system_ext/libmosey_daemon_ffi.so system_ext/manifest_mosey.xml \
    priv-app/MoseyApp/base.apk priv-app/MoseyApp/split_config.arm64_v8a.apk \
    priv-app/MoseyApp/split_config.xxhdpi.apk priv-app/MoseyApp/split_config.en.apk \
    permissions/privapp-permissions-mosey-vivo.xml permissions/mosey-hiddenapi-vivo.xml \
    || exit 0

apply_userspace || exit 0
refresh_once || exit 0
exit 0
