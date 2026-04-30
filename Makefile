# Kernel module Makefile — patched snd-hda-codec-alc269 for Yoga Pro 9 16IMH9
# alc269.c is the only compilation unit; helper .c files are #included from it.
# hda_common/ supplies internal HDA headers not shipped with kernel-headers.

obj-m := snd-hda-codec-alc269.o
snd-hda-codec-alc269-y := codecs/realtek/alc269.o

ccflags-y := -I$(src)/hda_common

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
