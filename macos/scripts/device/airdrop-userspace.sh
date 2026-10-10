#!/system/bin/sh
# Manually invoked helper. No boot hooks, no partition writes.
# Adds the global firmware's Mosey daemon library and VINTF declaration with two
# read-only OverlayFS mounts whose upper and work directories live on a private
# tmpfs, the same way vivo-mosey-privapp-device.sh handles /product. /system_ext
# (EROFS, dm-verity) is never remounted or written.
#   apply   mount the overlays and add the SELinux rules the daemon needs
#   status  show what is mounted and running
#   undo    unmount the overlays (SELinux rules stay until reboot)
set -eu

BASE=/mnt/vivo-airdrop
D=/data/local/tmp/airdrop
PAYLOAD="$D/payload"
LIB_TARGET=/system_ext/lib64
VINTF_TARGET=/system_ext/etc/vintf/manifest
LIB=libmosey_daemon_ffi.so
MANIFEST=manifest_mosey.xml
BB=/data/adb/ksu/bin/busybox
KSUD=/data/adb/ksud
# Mosey runs as priv_app on the CN ROM; mosey_server runs from this shell's ksu domain.
RULES='allow priv_app default_android_service service_manager find;
allow priv_app ksu binder { call transfer };
allow priv_app ksu fd use;
allow servicemanager ksu binder { call transfer };
allow servicemanager ksu dir search;
allow servicemanager ksu file { read open };
allow servicemanager ksu process getattr'

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die 'Run after your ADB shell has root (uid=0).'
if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
    [ -x "$BB" ] || die 'PID 1 mount namespace differs and KernelSU BusyBox is unavailable.'
    exec "$BB" nsenter -t 1 -m /system/bin/sh "$0" "$@"
fi

top_mount() {
    awk -v t="$1" '
        $5 == t { for (i = 7; i <= NF; i++) if ($i == "-") { line = $(i+1) " " $(i+3) } }
        END { if (line != "") print line }
    ' /proc/self/mountinfo
}

mount_state() {
    info="$(top_mount "$1")"
    [ -n "$info" ] || { echo absent; return; }
    case "$info" in
        "overlay "*"upperdir=$BASE/upper/$2,"*) echo owned ;;
        *) echo foreign ;;
    esac
}

stage() {
    mkdir -p "$BASE/upper/lib64" "$BASE/upper/vintf" "$BASE/work/lib64" "$BASE/work/vintf"
    cp "$PAYLOAD/lib64/$LIB" "$BASE/upper/lib64/$LIB"
    cp "$PAYLOAD/vintf/$MANIFEST" "$BASE/upper/vintf/$MANIFEST"
    chown -R 0:0 "$BASE/upper" "$BASE/work"
    chmod 0755 "$BASE/upper/lib64" "$BASE/upper/vintf"
    chmod 0644 "$BASE/upper/lib64/$LIB" "$BASE/upper/vintf/$MANIFEST"
    chcon -R u:object_r:system_lib_file:s0 "$BASE/upper/lib64" "$BASE/work/lib64"
    chcon -R u:object_r:system_file:s0 "$BASE/upper/vintf" "$BASE/work/vintf"
    (cd "$BASE/upper" && sha256sum -cs "$PAYLOAD/SHA256SUMS") || die 'Staged copies do not match the payload.'
}

undo_mounts() {
    rc=0
    for pair in "$LIB_TARGET:lib64" "$VINTF_TARGET:vintf"; do
        target="${pair%%:*}"; key="${pair##*:}"
        case "$(mount_state "$target" "$key")" in
            owned) umount "$target" 2>/dev/null || umount -l "$target" || rc=1 ;;
            foreign) echo "ERROR: a foreign mount covers $target; leaving it intact." >&2; rc=1 ;;
        esac
    done
    case "$(top_mount "$BASE")" in
        "tmpfs "*) umount "$BASE" 2>/dev/null || umount -l "$BASE" || rc=1 ;;
    esac
    return $rc
}

case "${1:-status}" in
    apply)
        (cd "$PAYLOAD" && sha256sum -cs SHA256SUMS) || die 'Payload checksum mismatch; push it again.'
        lib_state="$(mount_state "$LIB_TARGET" lib64)"; vintf_state="$(mount_state "$VINTF_TARGET" vintf)"
        [ "$lib_state" != foreign ] && [ "$vintf_state" != foreign ] || die 'A foreign mount covers a target.'
        if [ "$lib_state" = owned ] && [ "$vintf_state" = owned ]; then
            echo 'Overlays already mounted.'
        else
            undo_mounts >/dev/null || die 'Could not clear a partial previous state.'
            mkdir -p "$BASE"
            mount -t tmpfs -o mode=0755 tmpfs "$BASE"
            stage
            mount -t overlay overlay -o "ro,lowerdir=$LIB_TARGET,upperdir=$BASE/upper/lib64,workdir=$BASE/work/lib64" "$LIB_TARGET" ||
                { undo_mounts; die "Overlay on $LIB_TARGET failed."; }
            mount -t overlay overlay -o "ro,lowerdir=$VINTF_TARGET,upperdir=$BASE/upper/vintf,workdir=$BASE/work/vintf" "$VINTF_TARGET" ||
                { undo_mounts; die "Overlay on $VINTF_TARGET failed."; }
            [ -f "$LIB_TARGET/$LIB" ] && [ -f "$VINTF_TARGET/$MANIFEST" ] || { undo_mounts; die 'Files not visible after mounting.'; }
            echo "Mounted read-only overlays on $LIB_TARGET and $VINTF_TARGET."
        fi
        echo "$RULES" | while IFS= read -r rule; do
            "$KSUD" sepolicy patch "${rule%;}" || die "ksud rejected: $rule"
        done
        echo 'SELinux rules added. airdrop-start-server.sh makes servicemanager re-read VINTF; never restart servicemanager.'
        ;;
    status)
        echo "lib64_mount=$(mount_state "$LIB_TARGET" lib64)"
        echo "vintf_mount=$(mount_state "$VINTF_TARGET" vintf)"
        echo "modules=$(grep -oE '^(wonder_shim|wonder|qca_cld3_peach_v2) ' /proc/modules | tr -d '\n')"
        echo "mosey_server=$(pidof mosey_server || echo none)"
        ;;
    undo)
        undo_mounts && echo 'Overlays removed.'
        ;;
    *) die "usage: $0 apply|status|undo" ;;
esac
