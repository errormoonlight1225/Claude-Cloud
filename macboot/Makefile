# Convenience wrapper around Buildroot.  Usage:
#   make BUILDROOT=/path/to/buildroot          # build output/images/macboot.img
#   make BUILDROOT=/path/to/buildroot menuconfig
BUILDROOT ?= $(CURDIR)/../buildroot
O         ?= $(CURDIR)/output
EXT       := $(CURDIR)
BR        := $(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(EXT)

all: $(O)/.config
	$(BR)

$(O)/.config:
	$(BR) macboot_defconfig

menuconfig: $(O)/.config
	$(BR) menuconfig

savedefconfig:
	$(BR) savedefconfig BR2_DEFCONFIG=$(EXT)/configs/macboot_defconfig

clean:
	rm -rf $(O)

.PHONY: all menuconfig savedefconfig clean
