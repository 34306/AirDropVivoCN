#!/system/bin/sh
# Keeps mosey_server running. Started by service.sh with setsid so it survives
# the boot script. Runs in PID 1's mount namespace (common.sh re-execs it) so it
# sees the read-only /system_ext overlays. Never restarts servicemanager: the
# mtime touch below only makes libvintf re-read the manifest cache.
MODDIR=${MODDIR:-$(cd "${0%/*}/.." 2>/dev/null && pwd)}
export MODDIR
. "$MODDIR/bin/common.sh"

echo $$ > "$S/server.pid"
log "server: supervisor $$ started"
while true; do
    if [ -f "$SS_LIB/$LIB" ] && [ -f "$SS_VINTF/$VINTF" ]; then
        [ -e /apex/apex-info-list.xml ] && touch /apex/apex-info-list.xml
        if [ ! -x "$R/mosey_server" ]; then
            mkdir -p "$R"
            cp -f "$P/system_ext/mosey_server" "$R/mosey_server" && chmod 0755 "$R/mosey_server"
        fi
        log "server: starting mosey_server"
        "$R/mosey_server" >>"$LOG" 2>&1
        log "server: mosey_server exited $?"
    else
        log "server: waiting for the /system_ext overlay"
    fi
    sleep 3
done
