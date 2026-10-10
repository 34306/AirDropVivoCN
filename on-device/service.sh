#!/system/bin/sh
# Service stage. Starts the mosey_server supervisor plus the bounded watchdog that
# clears the boot-loop counter once Android has finished booting. Runs both in the
# initial late-load pass and (when the refresh runs the stage again) afterwards;
# both helpers are idempotent.
d=${0%/*}
[ "$d" = "$0" ] && d=$(pwd)
export MODDIR=$d
. "$MODDIR/bin/common.sh"

guard || exit 0
nohup setsid /system/bin/sh "$M/bin/watchdog.sh" >/dev/null 2>&1 &
server_start
exit 0
