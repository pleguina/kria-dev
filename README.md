# KV260 IMX477 capture pipeline

This repository contains the reproducible hardware, Device Tree, and Linux-driver
files for an Arducam Sony IMX477 on the KV260 Raspberry Pi camera connector (J9).
The validated path is:

```text
IMX477 (2-lane MIPI CSI-2 RAW10)
  -> D-PHY / CSI-2 RX
  -> hardware Bayer demosaic
  -> frame-buffer writer / DDR
  -> Linux V4L2 (/dev/video0)
```

The final hardware test reached live RGB video on Ubuntu 22.04.5 with the
`5.15.0-1077-xilinx-zynqmp` kernel. The design is built with Vivado 2024.1.

This board's SD card is shared with other Kria projects (PYNQ/DPU, etc.). If
you need to switch this board to a different project and back, see
[`SWITCHING.md`](SWITCHING.md) first.

## What is included

- `vivado/tcl/`: block-design and synthesis/implementation scripts.
- `vivado/xdc/kv260_imx477.xdc`: KV260 J9 pin constraints.
- `overlay/kv260_imx477.dts`: final `xmutil` Device Tree overlay.
- `driver/imx477_rpi-5.15/imx477.c`: IMX477 out-of-tree driver source.
- `driver/build/Makefile`: kernel-module build and install rules.
- `package/package.sh`: creates the deployable `xmutil` application.
- `package/kv260_imx477/`: final deployable bitstream, overlay, and metadata.
- `package/kria_load_test.sh`: board-side load, probe, and capture smoke test.
- `imx477_regs.json`: sensor mode and register reference.

Vivado projects, compiled modules, logs, intermediate overlays, and hardware
debug history are intentionally excluded. The experiment log and status summary
remain local working notes and are not part of this repository.

## Prerequisites

On the build host:

- Vivado 2024.1, with `bootgen` and `dtc` available.
- A KV260-compatible Ubuntu/Vitis kernel source tree or installed headers.
- Git, `make`, and a way to copy files to the board.

On the KV260:

```bash
sudo apt update
sudo apt install -y v4l-utils i2c-tools device-tree-compiler
```

Keep a serial console connected at 115200 baud while loading a new PL app.
Ethernet is recommended for SSH and file transfer.

## Build the FPGA design

Run from the repository root:

```bash
cd vivado
vivado -mode batch -source tcl/build_bd.tcl -source tcl/run_build.tcl
cd ..
```

The expected outputs are written to `vivado/out/`, including
`kv260_imx477.bit`. The design uses the IMX477's 900 Mbps/lane link rate and a
200 MHz video clock. Do not substitute the old 300 MHz configuration: it was
outside the documented video-IP limit and produced CSI-2 corruption.

## Build the IMX477 driver

Build against the target kernel headers, preferably on the KV260 or in a matching
cross-build environment:

```bash
make -C driver/build KDIR=/lib/modules/$(uname -r)/build
sudo make -C driver/build KDIR=/lib/modules/$(uname -r)/build install
```

The module requires the matching `5.15` V4L2/media API. Load it after the PL app
is active with `sudo modprobe imx477`.

## Package and deploy

After the Vivado build, package the bitstream and overlay on the host:

```bash
bash package/package.sh
scp -r package/kv260_imx477 ubuntu@<kv260>:/tmp/
scp driver/build/imx477.ko ubuntu@<kv260>:/tmp/
ssh ubuntu@<kv260> 'sudo mkdir -p /lib/firmware/xilinx/kv260_imx477 && sudo cp -f /tmp/kv260_imx477/* /lib/firmware/xilinx/kv260_imx477/ && sudo install -m 644 /tmp/imx477.ko /lib/modules/$(uname -r)/updates/imx477.ko && sudo depmod -a'
```

On the board:

```bash
sudo xmutil unloadapp
sudo xmutil loadapp kv260_imx477
sudo modprobe imx477
dmesg | grep -i imx477
media-ctl -p
```

Successful sensor probe includes `Device found is imx477`; the media graph should
contain `imx477 -> csi2rxss -> v_demosaic -> vcap_imx477` and expose `/dev/video0`.

The checked-in `package/kv260_imx477/` directory is already deployable, so the
Vivado build and packaging steps can be skipped when using that exact artifact.

## Configure and capture

The tested sensor mode is 1332x990, SRGGB10. Propagate it through the media graph
before capture:

```bash
media-ctl -d /dev/media0 -V '"imx477 6-001a":0 [fmt:SRGGB10_1X10/1332x990 field:none]'
media-ctl -d /dev/media0 -V '"80000000.csi2rxss":0 [fmt:SRGGB10_1X10/1332x990 field:none]'
media-ctl -d /dev/media0 -V '"80000000.csi2rxss":1 [fmt:SRGGB10_1X10/1332x990 field:none]'
media-ctl -d /dev/media0 -V '"80040000.v_demosaic":0 [fmt:SRGGB10_1X10/1332x990 field:none]'
media-ctl -d /dev/media0 -V '"80040000.v_demosaic":1 [fmt:RBG888_1X24/1332x990 field:none]'
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1332,height=990,pixelformat=RGB3
v4l2-ctl -d /dev/video0 --stream-mmap=3 --stream-count=1 --stream-to=frame.rgb
```

This design intentionally outputs demosaiced 8-bit RGB rather than raw Bayer
bytes. The stock Xilinx CSI receiver reports Bayer media-bus formats, while the
stock frame-buffer writer has no Bayer format entry; `v_demosaic` is therefore
required between them.

## Critical configuration details

- Keep the `afi0` node in every overlay. Without `xlnx,afi-fpga`, the first real
  AXI transaction during `axi_iic` probe caused an asynchronous SError and board
  panic.
- Keep both CSI line-rate properties at `900`: `C_HS_LINE_RATE` and
  `DPY_LINE_RATE`. They configure different layers of the receiver.
- Keep the sensor endpoint at two data lanes and
  `link-frequencies = <450000000>`.
- The final tested clock is 200 MHz. It eliminated the earlier CRC and line-buffer
  errors caused by the over-clocked 300 MHz design.

## Known limitations

- The sensor's built-in solid-color test pattern showed deterministic truncation
  in some single-shot captures. Real sensor captures were complete in the final
  live test.
- Earlier failed CSI-2 streams could leave a board soft-locked and require a
  power cycle. Stop testing promptly after a stream error and keep serial logging
  enabled.
- Image quality still depends on lens focus and has no hardware ISP stage for
  automatic white balance, color correction, gamma, or denoise.