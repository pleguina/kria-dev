#!/bin/bash
# package.sh -- turn the Vivado outputs into an xmutil app dir, on the PC.
# Produces:  package/kv260_imx477/{kv260_imx477.bit.bin, kv260_imx477.dtbo, shell.json}
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
source /tools/Xilinx/Vivado/2024.1/settings64.sh

BIT=$ROOT/vivado/out/kv260_imx477.bit
DTS=$ROOT/overlay/kv260_imx477.dts
APP=$HERE/kv260_imx477
mkdir -p "$APP"

[ -f "$BIT" ] || { echo "missing $BIT -- run the Vivado build first"; exit 1; }

# .bit -> .bit.bin (raw PL bitstream for fpga_manager / xmutil)
cp -f "$BIT" "$HERE/kv260_imx477.bit"
( cd "$HERE" && bootgen -image bootgen.bif -arch zynqmp -process_bitstream bin -w )
mv -f "$HERE/kv260_imx477.bit.bin" "$APP/kv260_imx477.bit.bin"
rm -f "$HERE/kv260_imx477.bit"

# device tree overlay
dtc -@ -I dts -O dtb -o "$APP/kv260_imx477.dtbo" "$DTS" 2>&1 | grep -vE "Warning \(unit_address_vs_reg\)|reg_format|avoid_default|pci_device|simple_bus_reg|i2c_bus_reg|spi_bus_reg|graph_child_address|unique_unit_address|avoid_unnecessary" || true

cp -f "$HERE/shell.json" "$APP/shell.json"

echo "=== app dir ==="
ls -l "$APP"
echo
echo "copy to the Kria with:"
echo "  scp -r $APP ubuntu@<kria>:/tmp/ && ssh ubuntu@<kria> 'sudo cp -r /tmp/kv260_imx477 /lib/firmware/xilinx/'"
