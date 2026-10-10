#!/system/bin/sh
# Put the phone's own Wi-Fi driver back. Runs on the phone as root.
D=/data/local/tmp/airdrop
exec >$D/restore.log 2>&1
set -x
cmd wifi set-wifi-enabled disabled
sleep 3
grep -q '^wonder ' /proc/modules && rmmod wonder
rmmod qca_cld3_peach_v2; echo "rmmod=$?"
sh $D/airdrop-firmware.sh undo
insmod /vendor_dlkm/lib/modules/qca_cld3_peach_v2.ko; echo "insmod=$?"
i=0; while [ $i -lt 30 ]; do ip link show wlan0 >/dev/null 2>&1 && break; sleep 1; i=$((i+1)); done
cmd wifi set-wifi-enabled enabled
sleep 5
cmd wifi status | head -3
echo done
