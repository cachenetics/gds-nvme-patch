#!/usr/bin/env bash
# lib/detect.sh - distro/kernel/environment detection for gds-nvme-patch.
# Sourced by install.sh (and, sparingly, uninstall.sh), and by lib/rebuild.sh
# via the gds-nvme-rebuild CLI. Every detect_* function sets one or more
# DETECTED_* globals and returns nonzero on failure so the caller can decide
# abort-vs-warn. No side effects other than reading files - safe to run
# without root.

# ---- kernel version override --------------------------------------------
# GDS_KVER lets a caller target a kernel version OTHER than the running one
# (lib/rebuild.sh does this - it rebuilds for a just-installed kernel during
# an unattended package-manager transaction, not the kernel this process is
# running under). Every place below that used to hardcode `$(uname -r)` now
# reads $GDS_KVER instead, so install.sh (GDS_KVER unset -> defaults to the
# running kernel, identical to before) and the rebuild hook (GDS_KVER set to
# the target kernel) share this exact same detection code. Set once, here,
# the first time this file is sourced.
GDS_KVER="${GDS_KVER:-$(uname -r)}"

# ---- arch / kernel -----------------------------------------------------

detect_arch() {
	DETECTED_ARCH="$(uname -m)"
	[ "$DETECTED_ARCH" = "x86_64" ]
}

detect_kernel_release() {
	DETECTED_KVER="$GDS_KVER"
	# the bare X.Y.Z used to fetch the matching stable-tree tag (strip any
	# distro suffix like "-2-cachyos" or "-arch1-1").
	DETECTED_KVER_BARE="$(printf '%s' "$DETECTED_KVER" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
	[ -n "$DETECTED_KVER_BARE" ]
}

# Requires the nvme pci.c source to already be fetched (build.sh does this
# before calling this). Era is determined by presence of the iterator-API
# entry point in the actual fetched source, not by version-number guessing -
# some distros backport it.
detect_nvme_api_era() {
	local pci_c="$1"
	[ -f "$pci_c" ] || { err "detect_nvme_api_era: $pci_c not found"; return 1; }
	if grep -q 'blk_rq_dma_map_iter_start' "$pci_c"; then
		DETECTED_NVME_API="iterator"
		return 0
	fi
	DETECTED_NVME_API="legacy"
	return 1
}

detect_headers() {
	DETECTED_KDIR="/lib/modules/$GDS_KVER/build"
	[ -d "$DETECTED_KDIR" ] && [ -f "$DETECTED_KDIR/Makefile" ]
}

# Toolchain the target kernel itself was built with, read from its own
# .config - a locally-built gcc kernel with a clang userspace (or vice versa)
# would otherwise mismatch and refuse to load the module (vermagic/GCC ABI).
detect_toolchain() {
	local cfg="/lib/modules/$GDS_KVER/build/.config"
	if [ -f "$cfg" ] && grep -q '^CONFIG_CC_IS_CLANG=y' "$cfg"; then
		DETECTED_TOOLCHAIN="clang"
	else
		DETECTED_TOOLCHAIN="gcc"
	fi
}

# ---- module compression -------------------------------------------------

detect_module_compression() {
	local dir="/lib/modules/$GDS_KVER/kernel/drivers/nvme/host"
	if [ -f "$dir/nvme.ko.zst" ]; then
		DETECTED_MOD_COMPRESS="zst"
	elif [ -f "$dir/nvme.ko.xz" ]; then
		DETECTED_MOD_COMPRESS="xz"
	elif [ -f "$dir/nvme.ko" ]; then
		DETECTED_MOD_COMPRESS="none"
	else
		err "no installed nvme.ko(.zst|.xz) found under $dir - can't determine compression"
		return 1
	fi
}

# ---- initramfs generator -------------------------------------------------

detect_initramfs_generator() {
	if command -v mkinitcpio >/dev/null 2>&1 && [ -d /etc/mkinitcpio.d ]; then
		DETECTED_INITRD_GEN="mkinitcpio"
	elif command -v dracut >/dev/null 2>&1; then
		DETECTED_INITRD_GEN="dracut"
	elif command -v update-initramfs >/dev/null 2>&1; then
		DETECTED_INITRD_GEN="update-initramfs"
	else
		err "no known initramfs generator found (mkinitcpio/dracut/update-initramfs)"
		return 1
	fi
}

# Best-effort match of the mkinitcpio preset for the TARGET kernel ($GDS_KVER,
# the running kernel unless overridden). Preset files don't reliably encode
# the kernel version in their name (e.g. a distro kernel package
# "linux-cachyos" ships "linux-cachyos.preset"), so we resolve each preset's
# ALL_kver/image path with `file` and compare the embedded kernel version
# string against $GDS_KVER. Falls back to "the only preset that exists" when
# there is exactly one.
detect_mkinitcpio_preset() {
	local presets=(/etc/mkinitcpio.d/*.preset)
	if [ ! -e "${presets[0]}" ]; then
		err "no *.preset files under /etc/mkinitcpio.d"
		return 1
	fi
	if [ "${#presets[@]}" -eq 1 ]; then
		DETECTED_MKINITCPIO_PRESET="$(basename "${presets[0]}" .preset)"
		return 0
	fi
	local p img ver
	for p in "${presets[@]}"; do
		# shellcheck disable=SC1090
		img="$(grep -oP '(?<=ALL_kver=").*(?=")' "$p" 2>/dev/null || true)"
		[ -z "$img" ] && img="$(grep -oP '(?<=_image=").*linux[^"]*(?="[[:space:]]*$)' "$p" 2>/dev/null | head -1 || true)"
		[ -z "$img" ] || [ ! -f "$img" ] && continue
		ver="$(file -b "$img" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ,]*' | head -1 || true)"
		if [ -n "$ver" ] && [ "$ver" = "$GDS_KVER" ]; then
			DETECTED_MKINITCPIO_PRESET="$(basename "$p" .preset)"
			return 0
		fi
	done
	err "could not match a mkinitcpio preset to target kernel $GDS_KVER (found ${#presets[@]} presets)"
	return 1
}

# Extract the initramfs image path(s) a preset produces, so build.sh can back
# them up before regenerating.
mkinitcpio_preset_images() {
	local preset="$1" f="/etc/mkinitcpio.d/${1}.preset"
	[ -f "$f" ] || return 1
	grep -oP '(?<=_image=").*(?=")' "$f" 2>/dev/null
}

# ---- bootloader -----------------------------------------------------------

detect_bootloader() {
	if [ -f /boot/grub/grub.cfg ]; then
		DETECTED_BOOTLOADER="grub"
		DETECTED_GRUB_CFG="/boot/grub/grub.cfg"
	elif [ -f /boot/grub2/grub.cfg ]; then
		DETECTED_BOOTLOADER="grub"
		DETECTED_GRUB_CFG="/boot/grub2/grub.cfg"
	elif [ -d /boot/loader/entries ] || [ -f /etc/kernel/cmdline ]; then
		DETECTED_BOOTLOADER="systemd-boot"
	else
		DETECTED_BOOTLOADER="unknown"
		return 1
	fi
}

detect_grub_mkconfig_bin() {
	if command -v grub-mkconfig >/dev/null 2>&1; then
		DETECTED_GRUB_MKCONFIG="grub-mkconfig"
	elif command -v grub2-mkconfig >/dev/null 2>&1; then
		DETECTED_GRUB_MKCONFIG="grub2-mkconfig"
	else
		err "neither grub-mkconfig nor grub2-mkconfig found"
		return 1
	fi
}

# Locate the single systemd-boot loader entry for the target kernel
# ($GDS_KVER). Return nonzero (caller prints manual instructions) rather than
# guess if there is not exactly one plausible match.
detect_systemd_boot_entry() {
	local d="/boot/loader/entries" matches=() f
	[ -d "$d" ] || return 1
	for f in "$d"/*.conf; do
		[ -f "$f" ] || continue
		grep -q "$GDS_KVER" "$f" && matches+=("$f")
	done
	if [ "${#matches[@]}" -eq 1 ]; then
		DETECTED_SDBOOT_ENTRY="${matches[0]}"
		return 0
	fi
	return 1
}

# ---- root filesystem / deployment mode -------------------------------------

detect_root_source() {
	DETECTED_ROOT_SOURCE="$(findmnt -no SOURCE / 2>/dev/null || true)"
	[ -n "$DETECTED_ROOT_SOURCE" ]
}

detect_root_fstype() {
	DETECTED_ROOT_FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || true)"
	[ -n "$DETECTED_ROOT_FSTYPE" ]
}

# Mode A (root on nvme, reboot required) vs Mode B (root elsewhere, live
# reload possible). Resolves the root source through symlinks/dm first so an
# nvme root behind LVM/dm-crypt is still recognized.
detect_deploy_mode() {
	detect_root_source || return 1
	local resolved="$DETECTED_ROOT_SOURCE"
	case "$resolved" in
	/dev/nvme*)
		DETECTED_MODE="A"
		return 0
		;;
	esac
	# dm/lvm/luks: walk slaves under sysfs for an nvme ancestor.
	local base s
	base="$(basename "$resolved")"
	if [ -d "/sys/class/block/$base/slaves" ]; then
		for s in "/sys/class/block/$base/slaves"/*; do
			[ -e "$s" ] || continue
			case "$(basename "$s")" in
			nvme*)
				DETECTED_MODE="A"
				return 0
				;;
			esac
		done
	fi
	DETECTED_MODE="B"
	return 0
}

# Find another installed kernel (not the running one) that still has a stock
# nvme module and its own initramfs, to serve as a rescue path for Mode A.
detect_rescue_kernel() {
	local running d kver has_mod has_initrd
	running="$(uname -r)"
	for d in /lib/modules/*/; do
		kver="$(basename "$d")"
		[ "$kver" = "$running" ] && continue
		[ -f "${d}modules.dep" ] || [ -f "${d}kernel/drivers/nvme/host/nvme.ko" ] \
			|| [ -f "${d}kernel/drivers/nvme/host/nvme.ko.zst" ] \
			|| [ -f "${d}kernel/drivers/nvme/host/nvme.ko.xz" ] || continue
		has_mod=0
		for e in "" .zst .xz; do
			[ -f "${d}kernel/drivers/nvme/host/nvme.ko${e}" ] && has_mod=1
		done
		[ "$has_mod" -eq 1 ] || continue
		has_initrd=0
		for pat in "/boot/initramfs-${kver}"* "/boot/initrd.img-${kver}"* "/boot/initramfs-linux"*.img; do
			[ -e "$pat" ] && has_initrd=1 && break
		done
		[ "$has_initrd" -eq 1 ] || continue
		DETECTED_RESCUE_KVER="$kver"
		return 0
	done
	return 1
}
