#!/system/bin/sh
# Bounded watchdog started by service.sh. Clears the boot-loop counter only once
# Android really finished booting, so a system_server crash loop still trips it.
MODDIR=${MODDIR:-$(cd "${0%/*}/.." 2>/dev/null && pwd)}
export MODDIR
. "$MODDIR/bin/common.sh"

i=0
while [ "$i" -lt 150 ]; do
    if [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]; then
        guard_ok
        exit 0
    fi
    sleep 4
    i=$((i + 1))
done
exit 0
