#!/system/bin/sh
# Manually invoked helper. No partition writes, no read-write remounts.
# Shows the global firmware's Wi-Fi image set (WLAN.GNG.2.0-01536, which supports the
# wondertap Passthru vdev) instead of the CN set, through a read-only bind mount of a
# private tmpfs over /vendor/firmware_mnt/image/peach. The CN firmware (01411) asserts
# when the driver starts a Passthru vdev, and vivo reboots the phone after the dump.
# The driver reads these files when it starts, so apply this before loading the driver.
#   apply | status | undo
set -eu

BASE=/mnt/vivo-airdrop-fw
SRC=/data/local/tmp/airdrop/fw-peach
TARGET=/vendor/firmware_mnt/image/peach
BB=/data/adb/ksu/bin/busybox
CTX=u:object_r:firmware_file:s0

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die 'Run after your ADB shell has root (uid=0).'
if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
    [ -x "$BB" ] || die 'PID 1 mount namespace differs and KernelSU BusyBox is unavailable.'
    exec "$BB" nsenter -t 1 -m /system/bin/sh "$0" "$@"
fi

# owned | foreign | absent for the top-most mount exactly at $TARGET.
state() {
    awk -v t="$TARGET" -v b="$BASE" '
        $5 == t { for (i = 7; i <= NF; i++) if ($i == "-") { line = $4 " " $(i+1) } }
        END {
            if (line == "") print "absent"
            else if (line == "/peach tmpfs") print "owned"
            else print "foreign"
        }' /proc/self/mountinfo
}

version() { grep -a -o 'QC_IMAGE_VERSION_STRING=[A-Za-z0-9._-]*' "$TARGET/amss20.bin" | head -1; }

case "${1:-status}" in
    apply)
        (cd "$SRC" && sha256sum -cs SHA256SUMS) || die 'Firmware payload checksum mismatch; push it again.'
        case "$(state)" in
            owned) echo "Global firmware already shown: $(version)"; exit 0 ;;
            foreign) die "Another mount covers $TARGET; leaving it intact." ;;
        esac
        grep -q '^qca_cld3_peach_v2 ' /proc/modules && echo 'Note: the Wi-Fi driver reads firmware when it starts; reload it to use this set.'
        mkdir -p "$BASE"
        grep -q " $BASE tmpfs " /proc/mounts || mount -t tmpfs -o mode=0755 tmpfs "$BASE"
        rm -rf "$BASE/peach"
        mkdir "$BASE/peach"
        for f in "$SRC"/*; do
            [ "$(basename "$f")" = SHA256SUMS ] || cp "$f" "$BASE/peach/"
        done
        chown -R 1000:1000 "$BASE/peach"
        chmod 0550 "$BASE/peach"
        chmod 0440 "$BASE/peach"/*
        chcon -R "$CTX" "$BASE/peach"
        (cd "$BASE/peach" && sha256sum -cs "$SRC/SHA256SUMS") || die 'Staged copies do not match the payload.'
        mount --bind "$BASE/peach" "$TARGET"
        mount -o remount,bind,ro "$TARGET" || { umount "$TARGET"; die 'Could not make the bind mount read-only.'; }
        [ "$(state)" = owned ] || { umount "$TARGET" 2>/dev/null; die 'Bind mount not visible.'; }
        echo "Bound global Wi-Fi firmware read-only over $TARGET: $(version)"
        ;;
    status)
        echo "firmware_mount=$(state) $(version)"
        ;;
    undo)
        case "$(state)" in
            owned) umount "$TARGET" || umount -l "$TARGET" ;;
            foreign) die "Another mount covers $TARGET; leaving it intact." ;;
        esac
        grep -q " $BASE tmpfs " /proc/mounts && { umount "$BASE" 2>/dev/null || umount -l "$BASE"; }
        echo "CN firmware shown again: $(version)"
        ;;
    *) die "usage: $0 apply|status|undo" ;;
esac
