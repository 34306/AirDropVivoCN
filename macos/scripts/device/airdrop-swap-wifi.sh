#!/system/bin/sh
# Replace the CN Wi-Fi driver with the global one that has the wondertap (Passthru) path.
# Runs on the phone as root, from /data/local/tmp/airdrop. Writes nothing outside /data.
# wonder_shim.ko must already be loaded: the global driver imports its symbols.
D=/data/local/tmp/airdrop
exec >$D/swap.log 2>&1
set -x
grep -q '^wonder_shim ' /proc/modules || { echo "wonder_shim is not loaded"; exit 1; }
cmd wifi set-wifi-enabled disabled
i=0; while [ $i -lt 20 ]; do cmd wifi status | grep -q "Wifi is disabled" && break; sleep 1; i=$((i+1)); done
sleep 2
ip -br link
dmesg -c >$D/dmesg-before-swap.txt
rmmod qca_cld3_peach_v2; echo "rmmod=$?"
sleep 1
dmesg -c >$D/dmesg-rmmod.txt
insmod $D/qca_cld3_peach_v2.ko; echo "insmod=$?"
i=0; while [ $i -lt 30 ]; do ip link show wlan0 >/dev/null 2>&1 && break; sleep 1; i=$((i+1)); done
ip -br link
dmesg >$D/dmesg-insmod.txt
echo done
