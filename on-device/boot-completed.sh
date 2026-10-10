#!/system/bin/sh
# Boot-completed stage. Only acts once the post-fs-data stage has run for this boot
# (otherwise we would be in the first late-load pass, before the refresh, when the
# framework has not rescanned and the app is not present yet). Then it binds the
# global Wi-Fi firmware read-only, swaps the CN driver for the global one (the
# firmware must be in place first), loads wonder, and grants/starts the Mosey app.
d=${0%/*}
[ "$d" = "$0" ] && d=$(pwd)
export MODDIR=$d
. "$MODDIR/bin/common.sh"

guard || exit 0
if ! post_fs_data_done; then
    log "boot-completed: post-fs-data has not run for this boot yet, skipping"
    exit 0
fi
guard_ok
payload_verify || exit 0
# The refresh restarted servicemanager, so restart the daemon against it.
server_stop
server_start
bringup
exit 0
