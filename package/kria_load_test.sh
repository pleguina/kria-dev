#!/bin/bash
# kria_load_test.sh -- run ON THE KRIA as root.
# Loads the kv260_imx477 PL app + overlay, probes the IMX477, brings up the V4L2
# pipeline, tries to grab a frame.  Verbose; safe to re-run.
set +e
APP=kv260_imx477
FW=/lib/firmware/xilinx/$APP
say(){ echo; echo "############ $* ############"; }

say "install app dir"
[ -d /tmp/$APP ] && { mkdir -p $FW; cp -f /tmp/$APP/* $FW/; }
ls -l $FW

say "current app"
xmutil listapps 2>&1 | sed -n '1,8p'

say "unload whatever is loaded, load $APP"
xmutil unloadapp 2>&1
sleep 1
xmutil loadapp $APP 2>&1
sleep 2

say "fpga state / overlays"
cat /sys/class/fpga_manager/fpga0/state
ls /sys/kernel/config/device-tree/overlays/

say "load imx477 module"
modprobe imx477 2>&1
sleep 1

say "dmesg (camera pipeline)"
dmesg | grep -Ei 'imx477|csi2rx|csiss|frmbuf|xilinx-video|xvipp|mipi|dphy|80000000|80010000|80030000|v4l2|media[0-9]|xlnx' | tail -80

say "i2c buses"
i2cdetect -l
for n in $(i2cdetect -l | sed -n 's/^i2c-\([0-9]*\).*/\1/p' | sort -n); do
  echo "--- i2c-$n ---"; i2cdetect -y -r $n 2>&1
done

say "v4l2 / media nodes"
ls -l /dev/video* /dev/media* /dev/v4l-subdev* 2>&1
v4l2-ctl --list-devices 2>&1
for m in /dev/media*; do [ -e "$m" ] && { echo "== $m =="; media-ctl -d $m -p 2>&1; }; done

say "try to configure + capture (SRGGB10 1332x990, adjust as needed)"
MED=/dev/media0
W=1332; H=990
if [ -e "$MED" ]; then
  SENSOR=$(media-ctl -d $MED -p | grep -o 'imx477 [0-9-]*' | head -1)
  # Each pad needs its own format, not a blanket one: csi2rxss's two pads and
  # demosaic's input pad stay Bayer (SRGGB10_1X10), but demosaic's output pad
  # is already converted to RGB (RBG888_1X24) -- the stock frame-buffer writer
  # has no Bayer format entry, so this conversion is required, and applying
  # SRGGB10_1X10 to that pad here would silently break the capture below.
  media-ctl -d $MED -V "\"$SENSOR\":0 [fmt:SRGGB10_1X10/${W}x${H} field:none]" 2>&1
  media-ctl -d $MED -V "\"80000000.csi2rxss\":0 [fmt:SRGGB10_1X10/${W}x${H} field:none]" 2>&1
  media-ctl -d $MED -V "\"80000000.csi2rxss\":1 [fmt:SRGGB10_1X10/${W}x${H} field:none]" 2>&1
  media-ctl -d $MED -V "\"80040000.v_demosaic\":0 [fmt:SRGGB10_1X10/${W}x${H} field:none]" 2>&1
  media-ctl -d $MED -V "\"80040000.v_demosaic\":1 [fmt:RBG888_1X24/${W}x${H} field:none]" 2>&1
  media-ctl -d $MED -p 2>&1 | grep -E 'fmt:|entity |video'
  V=$(ls /dev/video* 2>/dev/null | head -1)
  echo "capture device: $V"
  v4l2-ctl -d "$V" --set-fmt-video=width=${W},height=${H},pixelformat=RGB3 2>&1
  v4l2-ctl -d "$V" --stream-mmap=3 --stream-count=5 --stream-to=/tmp/frame.rgb --verbose 2>&1 | tail -20
  ls -l /tmp/frame.rgb 2>&1
fi

say "final dmesg tail"
dmesg | tail -30
