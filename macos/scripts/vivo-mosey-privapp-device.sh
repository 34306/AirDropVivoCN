#!/system/bin/sh
# Manually invoked helper. No boot hooks, no root acquisition, no partition writes.
# Promotes the installed Mosey APK splits to /product/priv-app and adds a
# product privapp allowlist using two read-only OverlayFS mounts whose upper
# and work directories live on a private tmpfs. /product (EROFS, dm-verity)
# is never remounted or written.
set -eu

BASE=/mnt/vivo-mosey-privapp
STATE=/data/local/vivo-mosey-privapp
PAYLOAD="$STATE/payload"
SUMS="$STATE/SHA256SUMS"
APP_TARGET=/product/priv-app
PERM_TARGET=/product/etc/permissions
APP_DIR=MoseyApp
PERM_XML=privapp-permissions-mosey-vivo.xml
PERM_FILES='privapp-permissions-mosey-vivo.xml mosey-hiddenapi-vivo.xml'
APKS='base.apk split_config.arm64_v8a.apk split_config.xxhdpi.apk split_config.en.apk'
BB=/data/adb/ksu/bin/busybox
CTX=u:object_r:system_file:s0

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die 'Run after your ADB shell has root (uid=0).'
if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
    [ -x "$BB" ] || die 'PID 1 mount namespace differs and KernelSU BusyBox is unavailable.'
    exec "$BB" nsenter -t 1 -m /system/bin/sh "$0" "$@"
fi

# Top-most mount at a path: prints "<fstype> <superblock options>" or nothing.
top_mount() {
    awk -v t="$1" '
        $5 == t { for (i = 7; i <= NF; i++) if ($i == "-") { line = $(i+1) " " $(i+3) } }
        END { if (line != "") print line }
    ' /proc/self/mountinfo
}

# owned | foreign | absent for one product target and its upper key.
mount_state() {
    info="$(top_mount "$1")"
    [ -n "$info" ] || { echo absent; return; }
    case "$info" in
        "overlay "*"upperdir=$BASE/upper/$2,"*) echo owned ;;
        *) echo foreign ;;
    esac
}

tmpfs_state() {
    info="$(top_mount "$BASE")"
    [ -n "$info" ] || { echo absent; return; }
    case "$info" in
        "tmpfs "*) echo owned ;;
        *) echo foreign ;;
    esac
}

label_of() { ls -Zd "$1" | awk '{print $1}'; }

# Payload layout mirrors the overlay upper layout:
#   payload/priv-app/MoseyApp/{base,split_config.*}.apk
#   payload/permissions/privapp-permissions-mosey-vivo.xml
#   SHA256SUMS (relative paths, produced on the Mac)
verify_tree() { (cd "$1" && sha256sum -cs "$SUMS") >/dev/null 2>&1; }

check_payload() {
    [ -d "$PAYLOAD" ] && [ ! -L "$PAYLOAD" ] || die 'Payload directory is missing; push it first.'
    [ -f "$SUMS" ] && [ ! -L "$SUMS" ] || die 'Payload checksum list is missing.'
    [ "$(grep -c . "$SUMS")" = 6 ] || die 'Checksum list must cover four APK splits and two XML files.'
    for apk in $APKS; do
        f="$PAYLOAD/priv-app/$APP_DIR/$apk"
        [ -f "$f" ] && [ ! -L "$f" ] || die "Missing APK split: $apk"
        grep -q " priv-app/$APP_DIR/$apk\$" "$SUMS" || die "Checksum list lacks $apk"
    done
    for xml in $PERM_FILES; do
        f="$PAYLOAD/permissions/$xml"
        [ -f "$f" ] && [ ! -L "$f" ] || die "Missing permission XML: $xml"
        grep -q " permissions/$xml\$" "$SUMS" || die "Checksum list lacks $xml"
    done
    verify_tree "$PAYLOAD" || die 'Payload checksum mismatch; push it again.'
}

# Populate upper/work trees under $1 (a tmpfs root) from the verified payload.
stage_upper() {
    root="$1"
    mkdir -p "$root/upper/priv-app/$APP_DIR" "$root/upper/permissions" \
             "$root/work/priv-app" "$root/work/permissions"
    for apk in $APKS; do
        cp "$PAYLOAD/priv-app/$APP_DIR/$apk" "$root/upper/priv-app/$APP_DIR/$apk"
    done
    for xml in $PERM_FILES; do
        cp "$PAYLOAD/permissions/$xml" "$root/upper/permissions/$xml"
    done
    chown -R 0:0 "$root/upper" "$root/work"
    chmod 0755 "$root/upper" "$root/upper/priv-app" "$root/upper/priv-app/$APP_DIR" "$root/upper/permissions"
    chmod 0644 "$root/upper/priv-app/$APP_DIR"/*.apk "$root/upper/permissions"/*.xml
    chcon -R "$CTX" "$root/upper" "$root/work"
    verify_tree "$root/upper" || die 'Staged copies do not match the payload.'
    [ "$(label_of "$root/upper/priv-app/$APP_DIR/base.apk")" = "$CTX" ] || die 'Could not label staged files.'
}

overlay_mount() {
    # $1 key (priv-app|permissions), $2 lower/target, $3 mountpoint, $4 tmpfs root
    mount -t overlay overlay -o "ro,lowerdir=$2,upperdir=$4/upper/$1,workdir=$4/work/$1" "$3"
}

undo_mounts() {
    rc=0
    for pair in "$APP_TARGET:priv-app" "$PERM_TARGET:permissions"; do
        target="${pair%%:*}"; key="${pair##*:}"
        case "$(mount_state "$target" "$key")" in
            owned)
                if umount "$target" 2>/dev/null; then
                    echo "Removed overlay: $target"
                elif umount -l "$target"; then
                    echo "Removed overlay (lazy detach, files were still open): $target"
                else
                    echo "ERROR: could not unmount $target" >&2; rc=1
                fi ;;
            foreign) echo "ERROR: a foreign mount covers $target; leaving it intact." >&2; rc=1 ;;
            absent) ;;
        esac
    done
    if [ "$(mount_state "$APP_TARGET" priv-app)" = absent ] && [ "$(mount_state "$PERM_TARGET" permissions)" = absent ]; then
        case "$(tmpfs_state)" in
            owned) umount "$BASE" 2>/dev/null || umount -l "$BASE" || rc=1 ;;
            foreign) echo "ERROR: unexpected mount at $BASE; leaving it intact." >&2; rc=1 ;;
        esac
        [ -d "$BASE" ] && [ "$(tmpfs_state)" = absent ] && rmdir "$BASE" 2>/dev/null || true
    fi
    return "$rc"
}

[ "$(getprop ro.product.model)" = V2547A ] || die 'This helper is for Vivo V2547A.'
[ "$(getprop ro.build.version.sdk)" = 36 ] || die 'This helper was prepared for Android 16 (API 36).'

case "${1:-inspect}" in
    inspect)
        echo "apps_mount=$(mount_state "$APP_TARGET" priv-app)"
        echo "permissions_mount=$(mount_state "$PERM_TARGET" permissions)"
        echo "tmpfs=$(tmpfs_state)"
        echo "apps_visible=$([ -f "$APP_TARGET/$APP_DIR/base.apk" ] && echo yes || echo no)"
        echo "permissions_visible=$([ -f "$PERM_TARGET/$PERM_XML" ] && echo yes || echo no)"
        echo "target_fs=$(stat -f -c '%T' "$APP_TARGET")"
        echo "payload=$([ -d "$PAYLOAD" ] && [ -f "$SUMS" ] && echo present || echo missing)"
        echo "privapp_enforce=$(getprop ro.control_privapp_permissions)"
        echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
        ;;
    selftest)
        # Full rehearsal on a scratch mountpoint. Product paths are not touched.
        check_payload
        grep -qw overlay /proc/filesystems || die 'Kernel lacks overlayfs.'
        scratch="$BASE-selftest"
        [ "$(top_mount "$scratch")" = '' ] || die 'Previous selftest mount still present.'
        mkdir -p "$scratch"
        mount -t tmpfs -o mode=0755 tmpfs "$scratch"
        trap 'umount -l "$scratch/merged/priv-app" 2>/dev/null; umount -l "$scratch/merged/permissions" 2>/dev/null; umount -l "$scratch" 2>/dev/null; rmdir "$scratch" 2>/dev/null' EXIT
        stage_upper "$scratch"
        mkdir -p "$scratch/merged/priv-app" "$scratch/merged/permissions"
        overlay_mount permissions "$PERM_TARGET" "$scratch/merged/permissions" "$scratch"
        overlay_mount priv-app "$APP_TARGET" "$scratch/merged/priv-app" "$scratch"
        [ -f "$scratch/merged/priv-app/$APP_DIR/base.apk" ] || die 'Selftest: APK not visible through overlay.'
        [ -f "$scratch/merged/permissions/$PERM_XML" ] || die 'Selftest: allowlist not visible through overlay.'
        [ -d "$scratch/merged/priv-app/GmsCore" ] || die 'Selftest: original product entries not visible through overlay.'
        [ "$(label_of "$scratch/merged/priv-app/$APP_DIR/base.apk")" = "$CTX" ] || die 'Selftest: wrong SELinux label.'
        [ "$(label_of "$scratch/merged/priv-app")" = "$CTX" ] || die 'Selftest: wrong directory label.'
        if touch "$scratch/merged/priv-app/.rwprobe" 2>/dev/null; then die 'Selftest: overlay is writable; expected read-only.'; fi
        echo "selftest=ok lower_entries=$(ls "$APP_TARGET" | wc -l) merged_entries=$(ls "$scratch/merged/priv-app" | wc -l)"
        ;;
    apply)
        check_payload
        grep -qw overlay /proc/filesystems || die 'Kernel lacks overlayfs.'
        [ -d "$APP_TARGET" ] && [ -d "$PERM_TARGET" ] || die 'Product directories are missing.'
        app_state="$(mount_state "$APP_TARGET" priv-app)"
        perm_state="$(mount_state "$PERM_TARGET" permissions)"
        [ "$app_state" != foreign ] || die "A foreign mount covers $APP_TARGET; leaving it intact."
        [ "$perm_state" != foreign ] || die "A foreign mount covers $PERM_TARGET; leaving it intact."
        [ "$(tmpfs_state)" != foreign ] || die "Unexpected mount at $BASE."
        if [ "$app_state" = owned ] && [ "$perm_state" = owned ]; then
            if verify_tree "$BASE/upper"; then
                echo 'Already applied; no additional mounts created.'
                exit 0
            fi
            echo 'Payload changed since the overlays were mounted; remounting.'
        fi
        # Partial state from an interrupted run: clear it and start over.
        undo_mounts >/dev/null || die 'Could not clear a partial previous state.'
        [ "$(stat -f -c '%T' "$APP_TARGET")" = erofs ] || die 'Expected /product/priv-app on EROFS; review the ROM first.'
        [ "$(stat -f -c '%T' "$PERM_TARGET")" = erofs ] || die 'Expected /product/etc/permissions on EROFS; review the ROM first.'
        [ ! -e "$APP_TARGET/$APP_DIR" ] || die "Product already contains $APP_DIR; refusing to shadow it."
        for xml in $PERM_FILES; do
            [ ! -e "$PERM_TARGET/$xml" ] || die "Product already contains $xml; refusing to shadow it."
        done

        mkdir -p "$BASE"
        mount -t tmpfs -o mode=0755 tmpfs "$BASE" || die 'Could not mount private tmpfs.'
        if ! stage_upper "$BASE"; then undo_mounts >/dev/null || true; exit 1; fi
        if ! overlay_mount permissions "$PERM_TARGET" "$PERM_TARGET" "$BASE"; then
            undo_mounts >/dev/null || true; die 'Overlay on /product/etc/permissions failed; nothing left mounted.'
        fi
        if ! overlay_mount priv-app "$APP_TARGET" "$APP_TARGET" "$BASE"; then
            undo_mounts >/dev/null || true; die 'Overlay on /product/priv-app failed; nothing left mounted.'
        fi
        if [ "$(mount_state "$APP_TARGET" priv-app)" != owned ] || [ "$(mount_state "$PERM_TARGET" permissions)" != owned ] ||
           [ ! -f "$APP_TARGET/$APP_DIR/base.apk" ] || [ ! -f "$PERM_TARGET/$PERM_XML" ] ||
           [ ! -f "$PERM_TARGET/mosey-hiddenapi-vivo.xml" ] ||
           [ "$(label_of "$APP_TARGET/$APP_DIR/base.apk")" != "$CTX" ] || [ ! -d "$APP_TARGET/GmsCore" ]; then
            undo_mounts >/dev/null || true
            die 'Post-mount verification failed; overlays were removed.'
        fi
        echo 'Applied two read-only overlays. Android must rescan packages (ksud soft-reboot).'
        ;;
    restore)
        undo_mounts
        ;;
    *) die 'Supported commands: inspect, selftest, apply, restore.' ;;
esac
