#!/system/bin/sh
# Keep mosey_server and the Mosey app running. Runs on the phone as root.
#   start (default)  start the supervisor unless one is running
#   stop             stop the supervisor and mosey_server
#   status           print the supervisor pid
# - servicemanager caches the VINTF manifest and re-reads it only when the mtime of
#   /apex/apex-info-list.xml changes (libvintf Get()), so this touches that file. Never
#   restart servicemanager: core services such as vold do not re-register, the framework
#   hangs, and the phone reboots with reason checkpoint_commit_failed.
# - Google Play services never starts Mosey, so this starts its service whenever the app is
#   gone, and restarts it whenever mosey_server got a new pid.
# - Android counts a started service as active for service_max_inactivity (30 minutes of
#   uptime) after it was last started or bound. Then Mosey's process is cached (adj >= 900),
#   the app freezer stops it, and Quick Share finds no Apple devices: opening Quick Share
#   does not thaw it. Starting the service again resets that clock and thaws the process.
# - Processes started from adb sit in adbd's cgroup, and init SIGKILLs everything in it
#   when adbd restarts, which happens whenever the USB configuration changes (cable plugged
#   in, USB mode chosen). The supervisor therefore moves itself to the root cgroup.
D=/data/local/tmp/airdrop
BB=/data/adb/ksu/bin/busybox
MOSEY=com.google.android.mosey
PF=/dev/vivo-airdrop-supervisor.pid

# The recorded pid, if that process is still this supervisor.
supervisor_pid() {
    p=$(cat $PF 2>/dev/null)
    [ -n "$p" ] && grep -q airdrop-start-server "/proc/$p/cmdline" 2>/dev/null && echo "$p"
}

case "${1:-start}" in
    status)
        p=$(supervisor_pid) && echo "supervisor=$p" || echo "supervisor=none"
        exit 0
        ;;
    stop)
        # The supervisor shell defers SIGTERM while it waits on a child, so it gets SIGKILL.
        p=$(supervisor_pid) && kill -9 "$p"
        rm -f $PF
        for p in $(pidof mosey_server); do kill "$p"; done
        sleep 2
        for p in $(pidof mosey_server); do kill -9 "$p"; done
        exit 0
        ;;
    start) ;;
    *) echo "usage: $0 [start|stop|status]" >&2; exit 1 ;;
esac

if p=$(supervisor_pid); then echo "supervisor $p is already running"; exit 0; fi
if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
    exec "$BB" nsenter -t 1 -m /system/bin/sh "$0" "$@"
fi
exec >>$D/mosey_server.log 2>&1
echo $$ > /sys/fs/cgroup/cgroup.procs || echo "$(date) warning: still in cgroup $(grep ^0:: /proc/$$/cgroup)"
echo $$ > $PF
echo "$(date) supervisor $$ start"
[ -f /system_ext/etc/vintf/manifest/manifest_mosey.xml ] || { echo "VINTF fragment missing; run airdrop-userspace.sh apply"; rm -f $PF; exit 1; }
[ -f /system_ext/lib64/libmosey_daemon_ffi.so ] || { echo "daemon library missing; run airdrop-userspace.sh apply"; rm -f $PF; exit 1; }
grep -q '^wonder ' /proc/modules || echo "warning: wonder.ko is not loaded"
touch /apex/apex-info-list.xml

# $server is the mosey_server pid the running Mosey was started against. A Mosey that was
# already running when the supervisor started is restarted once, since that is unknown.
server=unknown
while true; do
    if ! pidof mosey_server >/dev/null; then
        echo "$(date) starting mosey_server"
        $D/mosey_server &
        sleep 2
    fi
    s=$(pidof mosey_server); m=$(pidof $MOSEY)
    if [ "$(getprop sys.boot_completed)" = 1 ]; then
        adj=$(cat /proc/$m/oom_score_adj 2>/dev/null)
        if [ -z "$m" ]; then
            echo "$(date) starting Mosey"
        elif [ "$s" != "$server" ]; then
            echo "$(date) restarting Mosey (mosey_server $server -> $s)"
            am force-stop $MOSEY
        elif [ "${adj:-0}" -ge 900 ]; then
            echo "$(date) Mosey was cached (adj $adj); starting its service again"
        else
            sleep 5; continue
        fi
        am startservice --user 0 -n $MOSEY/.ExternalSharingService >/dev/null 2>&1
        server=$s
    fi
    sleep 5
done
