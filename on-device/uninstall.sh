#!/system/bin/sh
# Runs while Android is still up when the module is removed. Stops the daemon,
# puts the phone's own Wi-Fi driver back and drops every overlay/bind mount.
d=${0%/*}
[ "$d" = "$0" ] && d=$(pwd)
export MODDIR=$d
. "$MODDIR/bin/common.sh"

down
rm -rf "$S" "$R"
exit 0
