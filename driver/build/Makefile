# Out-of-tree build of the Raspberry Pi imx477 sensor driver for the
# Kria KV260 stock kernel (5.15.0-xxxx-xilinx-zynqmp).
obj-m += imx477.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_clean

install: all
	sudo install -m 644 imx477.ko /lib/modules/$(shell uname -r)/updates/
	sudo depmod -a
