# One FAI config space (./config) -> per architecture, two artifacts with the same package set:
#   build/cloud-$(ARCH).qcow2   disk image for clouds / VMs
#   build/metal-$(ARCH).iso     USB/ISO network installer for physical servers
# cloud-init configures both on first boot, from config/cloud-init/user-data.
#
# ARCH is amd64 or arm64 and defaults to the build host's. Images are built natively
# only (no emulated cross-builds): build arm64 on an arm64 host, e.g. the CI matrix in
# .github/workflows/build.yml. `make check` and `make packages ARCH=...` work anywhere.
#
# Building needs root (loop devices, chroots). `make check` and `make packages` don't.

CONFIG    := $(CURDIR)/config
BUILD     := $(CURDIR)/build
USERDATA  := $(CONFIG)/cloud-init/user-data
# Must match default_user in config/files/etc/cloud/cloud.cfg.d/90-fai-defaults.cfg/SERVER
SSH_USER  := jonathan
SUDO      ?= $(if $(filter 0,$(shell id -u)),,sudo)

HOST_ARCH := $(shell dpkg --print-architecture 2>/dev/null)
ARCH      ?= $(HOST_ARCH)
ARCHES    := amd64 arm64
ifeq ($(filter $(ARCH),$(ARCHES)),)
  $(error ARCH must be one of: $(ARCHES) (got '$(ARCH)'))
endif
ARCH_CLASS := $(if $(filter arm64,$(ARCH)),ARM64,AMD64)

# Builds run as root; hand the artifacts back to whoever ran `sudo make` so the
# QEMU tests (which run as a normal user) can read them. No-op without sudo.
give_back = @if [ -n "$$SUDO_USER" ]; then chown "$$SUDO_USER:" $(1) 2>/dev/null || true; fi
# Building is native only; refuse instead of silently producing the wrong architecture.
native_only = @[ "$(ARCH)" = "$(HOST_ARCH)" ] || { \
    echo "ERROR: building $(ARCH) on this $(HOST_ARCH) host needs emulation; build it on an $(ARCH) machine (see .github/workflows/build.yml)."; exit 1; }

# Classes are applied left to right; later *.var files override earlier ones.
# Cloud images are built with an explicit list (FAI then runs no class/ scripts and
# adds nothing itself, not even LAST), so list everything here.
cloud_classes = DEBIAN,FAIBASE,SERVER,HARDEN,CLOUD,$(1),DHCPC,GRUB_EFI,CLOUD_EFI,LAST
# What a metal install from the ISO ends up with (menu profile + class/ scripts),
# in the same order. Used for `make packages`; the install itself works it out live.
metal_classes = DEFAULT,$(1),DHCPC,INSTALL,FAIBASE,DEBIAN,SERVER,HARDEN,METAL,GRUB_EFI,METAL_EFI,LAST
CLOUD_CLASSES := $(call cloud_classes,$(ARCH_CLASS))
METAL_CLASSES := $(call metal_classes,$(ARCH_CLASS))
CLOUD_SIZE    := 3G

CLOUD_IMAGE := $(BUILD)/cloud-$(ARCH).qcow2
METAL_ISO   := $(BUILD)/metal-$(ARCH).iso
FAI_HOST    := cloud-$(ARCH)

# Rebuild artifacts whenever anything in the config space changes.
CONFIG_FILES := $(shell find $(CONFIG) -type f)

.PHONY: help deps check packages userdata-ready cloud metal-iso nfsroot \
        test-cloud test-metal boot-metal ssh clean

help:
	@echo "ARCH=$(ARCH) (host: $(HOST_ARCH)); override with ARCH=amd64|arm64"
	@echo "make deps        install build + test tooling (root)"
	@echo "make check       lint the config space, resolve package lists for all arches (no root)"
	@echo "make packages    show the exact package set for cloud and metal on ARCH (no root)"
	@echo "make cloud       build $(CLOUD_IMAGE) (+ manifest)"
	@echo "make metal-iso   build $(METAL_ISO)"
	@echo "make test-cloud  boot the cloud image in QEMU, configured by config/cloud-init/user-data"
	@echo "make test-metal  boot the metal ISO in QEMU against a blank 64G disk"
	@echo "make boot-metal  boot that disk after the install finished"
	@echo "make ssh         ssh into whichever test VM is running"

QEMU_PKGS_amd64 := qemu-system-x86 ovmf
QEMU_PKGS_arm64 := qemu-system-arm qemu-efi-aarch64
deps:
	$(SUDO) apt-get install -y --no-install-recommends make fai-server fai-setup-storage \
	    debootstrap xorriso squashfs-tools dosfstools mtools zstd ca-certificates mount udev \
	    qemu-utils $(QEMU_PKGS_$(HOST_ARCH)) cloud-image-utils openssh-client shellcheck ipxe-qemu
	getent group adm >/dev/null || $(SUDO) groupadd --system adm
	[ -e /etc/localtime ] || { $(SUDO) ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime && test -e /etc/localtime; }

check:
	@cd $(CONFIG) && bash -n class/[0-9]* scripts/*/* hooks/*.* bin/* files/usr/local/sbin/cis-check/HARDEN && echo "bash syntax: ok"
	@bash -n test/*.sh && echo "test scripts syntax: ok"
	@bash test/check-install-disk.sh
	@if command -v lvmconfig >/dev/null; then bash test/check-lvm-autoactivation.sh; \
	 else echo "installer LVM policy: skipped (install lvm2 to check)"; fi
	@cd $(CONFIG) && for f in scripts/*/* hooks/*.* bin/*; do [ -x "$$f" ] || { echo "not executable: $$f"; exit 1; }; done && echo "scripts executable: ok"
	@if command -v shellcheck >/dev/null; then \
	    shellcheck -S warning -e SC2154,SC2086,SC2034,SC2016 \
	        config/bin/* config/files/usr/local/sbin/cis-check/HARDEN config/scripts/SERVER/* config/scripts/HARDEN/* \
	        config/scripts/METAL/* config/scripts/CLOUD/20-* config/scripts/LAST/9* \
	        config/hooks/updatebase.DEBIAN config/hooks/partition.METAL.sh config/hooks/setup.DEFAULT.sh \
	        config/scripts/GRUB_EFI/05-initramfs test/*.sh \
	    && echo "shellcheck (our scripts): ok"; fi
	@head -1 $(USERDATA) | grep -qx '#cloud-config' || { echo "user-data must start with #cloud-config"; exit 1; }
	@! grep -nE '^\s*(packages|package_update|package_upgrade|apt)\s*:' $(USERDATA) || { \
	    echo "user-data installs packages; put them in config/package_config/ so every machine matches"; exit 1; }
	@echo "user-data: ok"
	@for c in AMD64 ARM64; do \
	    $(CONFIG)/bin/resolve-packages --source-vars $(CONFIG) $(call cloud_classes,$$c) >/dev/null && \
	    $(CONFIG)/bin/resolve-packages --source-vars $(CONFIG) $(call metal_classes,$$c) >/dev/null || exit 1; \
	 done && echo "package lists resolve (amd64, arm64): ok"

packages: | $(BUILD)
	@$(CONFIG)/bin/resolve-packages --source-vars $(CONFIG) $(CLOUD_CLASSES) > $(BUILD)/expected-cloud-$(ARCH).tsv
	@$(CONFIG)/bin/resolve-packages --source-vars $(CONFIG) $(METAL_CLASSES) > $(BUILD)/expected-metal-$(ARCH).tsv
	@echo "== $(ARCH): shared by every machine (package, action, from package_config/<class>):"
	@comm -12 $(BUILD)/expected-cloud-$(ARCH).tsv $(BUILD)/expected-metal-$(ARCH).tsv | column -t -s '	' | sed 's/^/   /'
	@echo "== $(ARCH): cloud only:"; comm -23 $(BUILD)/expected-cloud-$(ARCH).tsv $(BUILD)/expected-metal-$(ARCH).tsv | column -t -s '	' | sed 's/^/   /'
	@echo "== $(ARCH): metal only:"; comm -13 $(BUILD)/expected-cloud-$(ARCH).tsv $(BUILD)/expected-metal-$(ARCH).tsv | column -t -s '	' | sed 's/^/   /'
	@echo "(written to $(BUILD)/expected-{cloud,metal}-$(ARCH).tsv; dependencies come on top of these)"

# Root is locked and there are no passwords: without a key source nobody can log in.
userdata-ready:
	@grep -qE '^\s*(ssh_import_id|ssh_authorized_keys)\s*:' $(USERDATA) || { \
	    echo "ERROR: config/cloud-init/user-data has no ssh_import_id or ssh_authorized_keys; you would be locked out."; exit 1; }

$(BUILD):
	mkdir -p $@

# ---- cloud ------------------------------------------------------------------

cloud: $(CLOUD_IMAGE)
$(CLOUD_IMAGE): $(CONFIG_FILES) | $(BUILD)
	$(native_only)
	$(SUDO) rm -f $@
	$(SUDO) fai-diskimage -v -u $(FAI_HOST) -S $(CLOUD_SIZE) \
	    -s file://$(CONFIG) -c $(CLOUD_CLASSES) $@
	$(SUDO) cp /var/log/fai/$(FAI_HOST)/last/packages.tsv $(BUILD)/cloud-$(ARCH).packages.tsv \
	    || echo "note: no manifest in /var/log/fai/$(FAI_HOST)/last/; it is still inside the image at /var/lib/fai-build/"
	$(SUDO) cp /var/log/fai/$(FAI_HOST)/last/cis-check.txt $(BUILD)/cloud-$(ARCH).cis-check.txt || true
	$(call give_back,$(BUILD) $@ $(BUILD)/cloud-$(ARCH).packages.tsv $(BUILD)/cloud-$(ARCH).cis-check.txt)
	@echo "For AWS/GCE you usually want raw: qemu-img convert -O raw $@ $(BUILD)/cloud-$(ARCH).raw"

# ---- metal ------------------------------------------------------------------

# FAI's own settings (fai-server's /etc/fai) with what we don't want filtered out:
# - no memtest anywhere (fai-cd also adds a boot entry for it when it is in the nfsroot)
# - root locked in the installer: upstream sets the well-known password "fai", and the
#   hash would be readable in the public ISO anyway. For SSH during installs, set
#   SSH_IDENTITY (a public key) instead of a password.
# - no fai-project.org apt repo: its signing key fails verification, so FAI installed
#   its packages unauthenticated over plain HTTP. Debian's signed FAI is used instead.
# Next to the nfsroot so `make clean` keeps it and doesn't force an nfsroot rebuild.
FAI_ETC := /srv/fai/etc
$(FAI_ETC)/NFSROOT: Makefile $(wildcard /etc/fai/NFSROOT /etc/fai/*.conf /etc/fai/grub.cfg*)
	$(SUDO) rm -rf $(FAI_ETC)
	$(SUDO) mkdir -p $(dir $(FAI_ETC))
	$(SUDO) cp -a /etc/fai $(FAI_ETC)
	$(SUDO) sed -i '/memtest/d' $@
	$(SUDO) sed -i '/^FAI_ROOTPW=/d' $(FAI_ETC)/nfsroot.conf
	echo "FAI_ROOTPW='!'" | $(SUDO) tee -a $(FAI_ETC)/nfsroot.conf >/dev/null
	$(SUDO) sed -i '/fai-project\.org/d' $(FAI_ETC)/apt/sources.list
	# Use backports for the installer kernel and RTL8127 firmware.
	$(SUDO) sed -i -E 's#^(linux-image-(amd64|arm64))$$#\1/trixie-backports#; s#firmware-realtek([[:space:]]|$$)#firmware-realtek/trixie-backports\1#g' $@
	echo 'deb http://deb.debian.org/debian trixie-backports main non-free-firmware' | $(SUDO) tee -a $(FAI_ETC)/apt/sources.list >/dev/null
	# Network installs need DHCP even though the live root is on local media.
	$(SUDO) sed -i '/^[[:space:]]*linux[[:space:]]/s/$$/ ip=dhcp rd.neednet=1/' $(FAI_ETC)/grub.cfg

/srv/fai/nfsroot/.THIS_IS_THE_FAI_NFSROOT: $(FAI_ETC)/NFSROOT
	$(SUDO) fai-make-nfsroot -v -f -C $(FAI_ETC)

nfsroot: /srv/fai/nfsroot/.THIS_IS_THE_FAI_NFSROOT

# -M: no package mirror on the ISO; packages come from the network during install
# (same sources as the cloud build, including the APT_SNAPSHOT pin).
# The nfsroot (and so the ISO) is always the build host's architecture.
metal-iso: $(METAL_ISO)
$(METAL_ISO): Makefile $(CONFIG_FILES) | userdata-ready $(BUILD)
	$(native_only)
	$(MAKE) nfsroot
	$(SUDO) fai-cd -f -M -C $(FAI_ETC) -c $(CONFIG) $@
	$(call give_back,$(BUILD) $@)

# ---- test in QEMU -------------------------------------------------------------

test-cloud: userdata-ready
	ARCH=$(ARCH) test/qemu.sh cloud $(BUILD)

test-metal: userdata-ready
	ARCH=$(ARCH) test/qemu.sh metal-install $(BUILD)

boot-metal:
	ARCH=$(ARCH) test/qemu.sh metal-boot $(BUILD)

# Each test VM has fresh host keys, so don't record them for localhost:2222.
ssh:
	ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $(SSH_USER)@localhost

clean:
	$(SUDO) rm -rf $(BUILD) test/work
