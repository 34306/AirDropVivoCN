#!/system/bin/sh
# KernelSU "Action" button. Shows the state and drives the same flow the boot
# stages do: mount the overlays, and either refresh Android (first time) or run
# the Wi-Fi/app half (once the refresh has already happened this boot).
d=${0%/*}
[ "$d" = "$0" ] && d=$(pwd)
export MODDIR=$d
. "$MODDIR/bin/common.sh"

guard || { echo "this module only runs on the $MODEL (API 36)"; exit 1; }
echo "--- status"
status
echo "--- userspace overlays"
apply_userspace || true
if post_fs_data_done; then
    echo "--- bring-up"
    bringup
else
    echo "--- requesting an Android refresh (ksud soft-reboot)"
    refresh_once || true
fi
echo "--- status"
status
exit 0
