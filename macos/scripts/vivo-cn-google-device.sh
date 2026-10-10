#!/system/bin/sh
# Manually invoked helper. No boot hooks, root acquisition, or partition writes.
set -eu

TARGET=/product/etc/sysconfig/cn_feature.xml
STATE=/data/local/vivo-cn-google
PAYLOAD="$STATE/cn_feature.disabled.xml"
BB=/data/adb/ksu/bin/busybox

die() { echo "ERROR: $*" >&2; exit 1; }
file_id() { stat -L -c '%d:%i' "$1"; }
has_target_mount() {
    awk -v target="$TARGET" '$2 == target { found=1 } END { exit !found }' /proc/self/mounts
}
owns_target_mount() {
    has_target_mount && [ -f "$PAYLOAD" ] && [ ! -L "$PAYLOAD" ] &&
        [ "$(file_id "$TARGET")" = "$(file_id "$PAYLOAD")" ]
}
sha() { sha256sum "$1" | awk '{print $1}'; }

[ "$(id -u)" = 0 ] || die 'Run after your ADB shell has root (uid=0).'
if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
    [ -x "$BB" ] || die 'PID 1 mount namespace differs and KernelSU BusyBox is unavailable.'
    exec "$BB" nsenter -t 1 -m /system/bin/sh "$0" "$@"
fi
[ "$(getprop ro.product.model)" = V2547A ] || die 'This helper is for Vivo V2547A.'
[ "$(getprop ro.build.version.sdk)" = 36 ] || die 'This helper was prepared for Android 16 (API 36).'
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] || die 'Expected regular sysconfig XML is missing.'
[ ! -L "$STATE" ] || die 'State directory must not be a symlink.'
[ ! -L "$PAYLOAD" ] || die 'Payload must not be a symlink.'

case "${1:-inspect}" in
    inspect)
        if owns_target_mount; then
            echo 'mount=owned'
        elif has_target_mount; then
            echo 'mount=foreign'
        else
            echo 'mount=absent'
        fi
        echo "xml_sha256=$(sha "$TARGET")"
        echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
        ;;
    read-xml)
        cat "$TARGET"
        ;;
    apply)
        [ "$#" = 3 ] || die 'Usage: apply EXPECTED_ORIGINAL_SHA256 VALIDATED_XML_PATH'
        expected="$2"
        incoming="$3"
        [ "${#expected}" = 64 ] || die 'Invalid expected SHA-256 length.'
        case "$expected" in *[!0-9a-f]*) die 'Invalid expected SHA-256.' ;; esac
        case "$incoming" in /data/local/tmp/vivo-cn-google-input.xml) ;; *) die 'Unexpected incoming XML path.' ;; esac
        if owns_target_mount; then
            echo 'Already applied; no additional bind mount created.'
            exit 0
        fi
        has_target_mount && die 'A foreign mount covers the XML; leaving it intact.'
        [ "$(stat -f -c '%T' "$TARGET")" = erofs ] || die 'Expected original XML on EROFS; a directory overlay or changed ROM must be reviewed first.'
        [ "$(sha "$TARGET")" = "$expected" ] || die 'Original XML changed since validation.'
        [ -f "$incoming" ] && [ ! -L "$incoming" ] || die 'Validated incoming XML is missing.'
        grep -q '<unavailable-feature name="cn.google.services"' "$incoming" || die 'Missing unavailable-feature declaration.'
        grep -q 'com.google.android.feature.services_updater' "$incoming" || die 'Missing services updater feature.'
        mkdir -p "$STATE"
        chown 0:0 "$STATE"
        chmod 0700 "$STATE"
        [ "$(stat -c '%u' "$STATE")" = 0 ] || die 'State directory is not owned by root.'
        backup="$STATE/cn_feature.original.$expected.xml"
        [ ! -L "$backup" ] && [ ! -L "$PAYLOAD.tmp" ] || die 'Unexpected state symlink.'
        if [ ! -e "$backup" ]; then
            cp "$TARGET" "$backup"
            chmod 0600 "$backup"
        fi
        [ "$(sha "$backup")" = "$expected" ] || die 'Backup content mismatch.'
        cp "$incoming" "$PAYLOAD.tmp"
        chown 0:0 "$PAYLOAD.tmp"
        chmod 0644 "$PAYLOAD.tmp"
        chcon u:object_r:system_file:s0 "$PAYLOAD.tmp"
        mv "$PAYLOAD.tmp" "$PAYLOAD"
        mount -o bind "$PAYLOAD" "$TARGET"
        if ! owns_target_mount; then
            umount "$TARGET"
            die 'Bind identity check failed; newly created mount was removed.'
        fi
        echo 'Applied one XML bind mount. Android must reread SystemConfig.'
        ;;
    restore)
        if owns_target_mount; then
            umount "$TARGET"
            echo "Removed this script's bind; original ROM XML is visible."
        elif has_target_mount; then
            die 'A foreign mount covers the XML; leaving it intact.'
        else
            echo 'No bind from this script is active.'
        fi
        ;;
    *) die 'Supported commands: inspect, read-xml, apply, restore.' ;;
esac
