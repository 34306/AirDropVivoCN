#!/system/bin/sh
# KernelSU installer customization. Validates the target device and the payload,
# then fixes permissions. No files are installed into a system partition.
SKIPUNZIP=0

ui_print "- vivo X300 Ultra CN AirDrop (V2547A)"
ui_print "- kernel: $(uname -r)"

[ "$(getprop ro.product.model)" = "V2547A" ] \
    || abort "this module is only for the vivo X300 Ultra CN (V2547A); found $(getprop ro.product.model)"
[ "$(getprop ro.build.version.sdk)" = "36" ] \
    || abort "expected Android 16 (API 36); found API $(getprop ro.build.version.sdk)"

ui_print "- verifying payload"
(cd "$MODPATH/payload" && sha256sum -cs SHA256SUMS) \
    || abort "payload checksum mismatch; re-download the module zip"

set_perm_recursive "$MODPATH/payload" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm "$MODPATH/payload/system_ext/mosey_server" 0 0 0755
for f in late-load.sh post-fs-data.sh service.sh boot-completed.sh action.sh uninstall.sh; do
    set_perm "$MODPATH/$f" 0 0 0755
done

ui_print "- installed; activate root (late-load) to mount the overlays and refresh Android"
