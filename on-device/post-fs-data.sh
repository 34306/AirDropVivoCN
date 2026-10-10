#!/system/bin/sh
# Post-fs-data stage. Runs at a real boot, and (with late-load) inside the
# `ksud soft-reboot` that refreshes Android, while the framework is stopped. That
# makes it the right moment to have the overlays live, so they are (re)mounted
# here too (idempotent) and the per-boot marker is written that tells
# boot-completed.sh the overlays are in place for this boot.
d=${0%/*}
[ "$d" = "$0" ] && d=$(pwd)
export MODDIR=$d
. "$MODDIR/bin/common.sh"

guard || exit 0
guard_boot || exit 0
if post_fs_data_done; then
    log "post-fs-data: already applied for this boot, nothing to do"
    exit 0
fi

payload_verify \
    system_ext/libmosey_daemon_ffi.so system_ext/manifest_mosey.xml \
    priv-app/MoseyApp/base.apk priv-app/MoseyApp/split_config.arm64_v8a.apk \
    priv-app/MoseyApp/split_config.xxhdpi.apk priv-app/MoseyApp/split_config.en.apk \
    permissions/privapp-permissions-mosey-vivo.xml permissions/mosey-hiddenapi-vivo.xml \
    || exit 0

apply_userspace || exit 0
post_fs_data_mark
clean_old_markers
exit 0
