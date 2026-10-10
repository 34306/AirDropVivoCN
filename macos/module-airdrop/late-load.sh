#!/system/bin/sh
# KernelSU Next runs this after `ksud late-load`. Start the bring-up in the background so the
# late-load stage is not held up; progress goes to /data/local/tmp/airdrop/autostart.log.
S=/data/local/tmp/airdrop/airdrop-autostart.sh
[ -f "$S" ] && nohup /data/adb/ksu/bin/busybox setsid sh "$S" </dev/null >/dev/null 2>&1 &
exit 0
