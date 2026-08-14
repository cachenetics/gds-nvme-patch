#!/usr/bin/env bash
# install.sh - distro-agnostic installer for the GDS nvme host-driver patch.
#
# Detects the running kernel/distro, fetches the matching nvme host source,
# applies lib/patch_nvme.py (which refuses on any anchor mismatch), builds
# nvme.ko out-of-tree, and installs it - either live (root not on nvme) or
# staged for the next boot (root on nvme). See README.md for the full
# picture; this file is the orchestrator, lib/detect.sh and lib/build.sh do
# the actual detection/build work.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
STATE_DIR="/var/lib/gds-nvme-patch"

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
err()  { printf '[err ] %s\n' "$*" >&2; }
abort() { err "$*"; exit 1; }

# shellcheck source=lib/detect.sh
. "$REPO_ROOT/lib/detect.sh"
# shellcheck source=lib/build.sh
. "$REPO_ROOT/lib/build.sh"

usage() {
	cat <<'EOF'
Usage: install.sh [--dry-run] [--force] [--src-dir=PATH] [--persist|--no-persist] [-h|--help]

  --dry-run      Detect, fetch, patch, build, and verify vermagic only. Does
                 not touch /lib/modules, /boot, depmod, or reload anything.
  --force        Proceed past non-fatal safety refusals (e.g. no rescue kernel
                 found for Mode A). Never bypasses the patcher's anchor asserts.
  --src-dir=PATH Use kernel source from PATH (must contain
                 drivers/nvme/host/pci.c) instead of fetching from mainline.
                 Use this if your distro patches its nvme driver so the mainline
                 source does not match (e.g. 'apt-get source linux' on Ubuntu,
                 then --src-dir=./linux-<ver>). Also used automatically if a
                 local kernel source tree is detected.
  --persist      (default) After a successful install, copy this tool to
                 /usr/lib/gds-nvme-patch/ and install a distro-appropriate
                 kernel-update hook (pacman/apt/dnf) so future kernel updates
                 auto-rebuild the patch instead of silently reverting to the
                 stock nvme driver. See docs/PERSISTENCE.md.
  --no-persist   Skip the above; a kernel update will revert to stock nvme
                 until you rerun install.sh by hand.
  -h, --help     Show this help.
EOF
}

DRY_RUN=0
FORCE=0
SRC_DIR=""
PERSIST=1
for a in "$@"; do
	case "$a" in
	--dry-run) DRY_RUN=1 ;;
	--force) FORCE=1 ;;
	--src-dir=*) SRC_DIR="${a#*=}" ;;
	--persist) PERSIST=1 ;;
	--no-persist) PERSIST=0 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		err "unknown argument: $a"
		usage
		exit 1
		;;
	esac
done

# ---- persistence helpers (kernel-update hook install) ----------------------
# Pure detection (no writes) so it can run before the root check and be
# reused by both the --dry-run report and the real --persist install below.
detect_persist_family() {
	if command -v pacman >/dev/null 2>&1 && [ -d /etc/pacman.d ]; then
		printf 'pacman\n'
		return 0
	fi
	if command -v dpkg >/dev/null 2>&1 || [ -d /etc/kernel/postinst.d ]; then
		printf 'debian\n'
		return 0
	fi
	if command -v rpm >/dev/null 2>&1 || [ -d /etc/kernel/install.d ]; then
		printf 'fedora\n'
		return 0
	fi
	return 1
}

# install_persist <family>
# Copies the tool to a stable location and installs the one hook for
# <family>. Only called after a real (non-dry-run) successful install.
install_persist() {
	local family="$1" target="/usr/lib/gds-nvme-patch"
	info "installing persistence: copying tool to $target"
	mkdir -p "$target/lib" "$target/hooks"
	install -m 0644 "$REPO_ROOT/lib/patch_nvme.py" "$target/lib/patch_nvme.py"
	install -m 0644 "$REPO_ROOT/lib/detect.sh" "$target/lib/detect.sh"
	install -m 0644 "$REPO_ROOT/lib/build.sh" "$target/lib/build.sh"
	install -m 0644 "$REPO_ROOT/lib/rebuild.sh" "$target/lib/rebuild.sh"
	install -m 0755 "$REPO_ROOT/gds-nvme-rebuild" "$target/gds-nvme-rebuild"

	case "$family" in
	pacman)
		mkdir -p /etc/pacman.d/hooks
		install -m 0755 "$REPO_ROOT/hooks/pacman/pacman-trigger.sh" "$target/pacman-trigger.sh"
		install -m 0644 "$REPO_ROOT/hooks/pacman/gds-nvme-patch.hook" /etc/pacman.d/hooks/gds-nvme-patch.hook
		info "installed pacman hook: /etc/pacman.d/hooks/gds-nvme-patch.hook"
		;;
	debian)
		mkdir -p /etc/kernel/postinst.d
		install -m 0755 "$REPO_ROOT/hooks/debian/zz-gds-nvme-patch" /etc/kernel/postinst.d/zz-gds-nvme-patch
		info "installed debian kernel postinst hook: /etc/kernel/postinst.d/zz-gds-nvme-patch"
		;;
	fedora)
		mkdir -p /etc/kernel/install.d
		install -m 0755 "$REPO_ROOT/hooks/fedora/95-gds-nvme-patch.install" /etc/kernel/install.d/95-gds-nvme-patch.install
		info "installed fedora kernel-install plugin (template-quality, see docs/PERSISTENCE.md): /etc/kernel/install.d/95-gds-nvme-patch.install"
		;;
	esac
	info "persistence installed: future kernel updates for supported kernels will auto-rebuild the patch (sudo ./uninstall.sh removes these hooks + $target)"
}

PERSIST_FAMILY="$(detect_persist_family || true)"

if [ -n "$SRC_DIR" ] && [ ! -f "${SRC_DIR%/}/drivers/nvme/host/pci.c" ]; then
	abort "--src-dir='$SRC_DIR' does not contain drivers/nvme/host/pci.c"
fi

if [ "$(id -u)" -ne 0 ]; then
	abort "must be run as root (sudo ./install.sh ${*})"
fi

WORKDIR="$(mktemp -d /tmp/gds-nvme-patch.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

info "=== gds-nvme-patch installer ==="

# ---- 1. arch / kernel / headers -------------------------------------------

detect_arch || abort "unsupported architecture '$DETECTED_ARCH' - x86_64 only"
info "arch: $DETECTED_ARCH"

detect_kernel_release || abort "could not parse a X.Y.Z release out of 'uname -r' ($(uname -r))"
info "kernel: $(uname -r)  (fetching source for v${DETECTED_KVER_BARE})"

detect_headers || abort "kernel headers not found at /lib/modules/$(uname -r)/build - install them first (e.g. linux-headers)"
info "headers: $DETECTED_KDIR"

detect_toolchain
info "kernel build toolchain: $DETECTED_TOOLCHAIN"

detect_root_source || abort "could not resolve the root filesystem's source device (findmnt -no SOURCE /)"
detect_root_fstype || abort "could not resolve the root filesystem's type (findmnt -no FSTYPE /)"
detect_deploy_mode
if [ "$DETECTED_MODE" = "A" ]; then
	info "root device: $DETECTED_ROOT_SOURCE (on nvme) -> Mode A (reboot required)"
else
	info "root device: $DETECTED_ROOT_SOURCE (not on nvme) -> Mode B (live reload, no reboot)"
fi

# ---- 2. fetch + era check + patch + build ----------------------------------

get_nvme_source "$DETECTED_KVER_BARE" "$WORKDIR" "$SRC_DIR" \
	|| abort "kernel source acquisition failed - see above. If your distro patches its kernel, point at its source with --src-dir=<path> (e.g. 'apt-get source linux' on Debian/Ubuntu)."

detect_nvme_api_era "$WORKDIR/pci.c" || abort \
	"this kernel's pci.c uses the legacy blk_rq_map_sg/dma_map_sg nvme API (pre-6.18), not blk_rq_dma_map_iter. Use NVIDIA's MOFED/DOCA nvme patch for this kernel instead - this repo only targets the 6.18+ iterator API."
info "nvme DMA API: $DETECTED_NVME_API (blk_rq_dma_map_iter present, kernel is new enough)"

write_build_makefile "$WORKDIR"

info "applying patch (lib/patch_nvme.py)"
apply_nvme_patch "$WORKDIR" "$REPO_ROOT" || abort \
	"patch refused - this kernel's pci.c layout does not match the patch's anchors. The kernel's nvme driver has likely changed shape since this patch was written; the anchors need updating for this version. Do not bypass this - open an issue with your drivers/nvme/host/pci.c. Aborting, nothing was touched."

info "building nvme.ko ($DETECTED_TOOLCHAIN)"
build_nvme_module "$WORKDIR" "$DETECTED_TOOLCHAIN" || abort "build failed - see compiler output above"

KO="$WORKDIR/nvme.ko"
[ -f "$KO" ] || abort "build reported success but $KO does not exist"

verify_vermagic "$KO" || abort "refusing to install a module with a mismatched vermagic"
info "vermagic OK: matches $(uname -r)"

verify_nvfs_symbol "$KO" || abort "built module is missing nvme_v2_register_nvfs_dma_ops - patch/build did not do what it should have"
info "symbol OK: nvme_v2_register_nvfs_dma_ops present"

# ---- 3. remaining environment detection (module compression, initramfs, bootloader) ----

detect_module_compression || abort "could not determine the installed nvme module's compression format"
case "$DETECTED_MOD_COMPRESS" in
none) info "module compression: none (.ko)" ;;
*) info "module compression: $DETECTED_MOD_COMPRESS (.ko.$DETECTED_MOD_COMPRESS)" ;;
esac

detect_initramfs_generator || abort "no supported initramfs generator found"
info "initramfs generator: $DETECTED_INITRD_GEN"

MKINITCPIO_PRESET=""
if [ "$DETECTED_INITRD_GEN" = "mkinitcpio" ]; then
	detect_mkinitcpio_preset || abort "could not identify the mkinitcpio preset for the running kernel - pass it manually by editing install.sh (see lib/detect.sh:detect_mkinitcpio_preset)"
	MKINITCPIO_PRESET="$DETECTED_MKINITCPIO_PRESET"
	info "mkinitcpio preset: $MKINITCPIO_PRESET"
fi

CMDLINE_STEP="skip"
if [ "$DETECTED_ROOT_FSTYPE" = "ext4" ]; then
	if detect_bootloader; then
		info "bootloader: $DETECTED_BOOTLOADER"
		case "$DETECTED_BOOTLOADER" in
		grub)
			detect_grub_mkconfig_bin || abort "grub.cfg present but no grub-mkconfig/grub2-mkconfig binary found"
			info "grub config: $DETECTED_GRUB_CFG (via $DETECTED_GRUB_MKCONFIG)"
			CMDLINE_STEP="grub"
			;;
		systemd-boot)
			if detect_systemd_boot_entry; then
				info "systemd-boot entry: $DETECTED_SDBOOT_ENTRY"
				CMDLINE_STEP="systemd-boot"
			else
				warn "systemd-boot detected but could not uniquely identify the loader entry for $(uname -r)."
				warn "Manual step needed after install: add 'rootflags=data=ordered' to the 'options' line"
				warn "of your /boot/loader/entries/*.conf entry for this kernel (or /etc/kernel/cmdline)."
				CMDLINE_STEP="manual"
			fi
			;;
		esac
	else
		warn "root fs is ext4 but no supported bootloader (grub/systemd-boot) was detected."
		warn "Manual step needed: add 'rootflags=data=ordered' to your kernel cmdline yourself."
		CMDLINE_STEP="manual"
	fi
else
	info "root fs is '$DETECTED_ROOT_FSTYPE' (not ext4) - skipping rootflags=data=ordered (cuFile's ext4-only check does not apply)"
fi

# ---- 4. plan summary --------------------------------------------------------

info "--- plan ---"
info "mode:            Mode $DETECTED_MODE $([ "$DETECTED_MODE" = A ] && echo '(reboot required)' || echo '(live reload, no reboot)')"
info "module install:  /lib/modules/$(uname -r)/kernel/drivers/nvme/host/nvme.ko(.${DETECTED_MOD_COMPRESS})"
info "initramfs:       $DETECTED_INITRD_GEN${MKINITCPIO_PRESET:+ (preset: $MKINITCPIO_PRESET)}"
info "cmdline step:    $CMDLINE_STEP"

if [ "$DRY_RUN" -eq 1 ]; then
	info "--dry-run: stopping here. Nothing under /lib/modules, /boot, or the module tree was touched."
	info "built module left at: $KO (removed on exit; use --dry-run output above to confirm before a real run)"
	if [ "$PERSIST" -eq 1 ]; then
		if [ -n "$PERSIST_FAMILY" ]; then
			info "--persist plan: would copy tool to /usr/lib/gds-nvme-patch/ and install a $PERSIST_FAMILY kernel-update hook (not done under --dry-run)"
		else
			warn "--persist plan: no supported package manager (pacman/apt/dnf) detected - persistence would be SKIPPED even on a real run. See docs/PERSISTENCE.md to wire a hook manually."
		fi
	else
		info "--no-persist: no kernel-update hook would be installed"
	fi
	exit 0
fi

# ---- 5. Mode A rescue-kernel safety gate -----------------------------------

if [ "$DETECTED_MODE" = "A" ]; then
	if detect_rescue_kernel; then
		info "rescue kernel found: $DETECTED_RESCUE_KVER (stock nvme module + its own initramfs, untouched by this installer)"
	else
		if [ "$FORCE" -eq 1 ]; then
			warn "no rescue kernel found, but --force given - proceeding anyway. A bad build here can leave you with no bootable fallback."
		else
			abort "no other installed kernel with a stock nvme module + its own initramfs was found. This is Mode A (root on nvme) - a bad build could make the box unbootable with no rescue path. Install a second kernel first, or pass --force to proceed anyway (not recommended)."
		fi
	fi
fi

# ---- 6. backup + install the module ----------------------------------------

KVER="$(uname -r)"
BACKUP_DIR="${STATE_DIR}/backups/${KVER}"
mkdir -p "$BACKUP_DIR/module" "$BACKUP_DIR/initramfs" "$BACKUP_DIR/bootloader"

STOCK_MOD_DIR="/lib/modules/${KVER}/kernel/drivers/nvme/host"
case "$DETECTED_MOD_COMPRESS" in
none) STOCK_MOD="${STOCK_MOD_DIR}/nvme.ko" ;;
zst) STOCK_MOD="${STOCK_MOD_DIR}/nvme.ko.zst" ;;
xz) STOCK_MOD="${STOCK_MOD_DIR}/nvme.ko.xz" ;;
esac

if [ -f "${BACKUP_DIR}/module/$(basename "$STOCK_MOD")" ]; then
	info "stock module already backed up at ${BACKUP_DIR}/module/ (from a previous install) - not overwriting the backup"
else
	info "backing up stock module: $STOCK_MOD -> ${BACKUP_DIR}/module/"
	cp -a "$STOCK_MOD" "${BACKUP_DIR}/module/"
fi

info "compressing built module to match installed format ($DETECTED_MOD_COMPRESS)"
NEW_MOD="$(compress_module_like "$KO" "$DETECTED_MOD_COMPRESS" "${WORKDIR}/nvme-patched")"

info "installing patched module over $STOCK_MOD"
install -m 0644 "$NEW_MOD" "$STOCK_MOD"

info "depmod -a"
depmod -a "$KVER"

# ---- 7. backup + regenerate initramfs (current kernel only) ---------------

INITRD_FILES=()
case "$DETECTED_INITRD_GEN" in
mkinitcpio)
	while IFS= read -r img; do
		[ -n "$img" ] && INITRD_FILES+=("$img")
	done < <(mkinitcpio_preset_images "$MKINITCPIO_PRESET")
	;;
dracut)
	INITRD_FILES+=("/boot/initramfs-${KVER}.img")
	;;
update-initramfs)
	INITRD_FILES+=("/boot/initrd.img-${KVER}")
	;;
esac

for f in "${INITRD_FILES[@]}"; do
	if [ -f "$f" ]; then
		info "backing up initramfs: $f -> ${BACKUP_DIR}/initramfs/"
		cp -a "$f" "${BACKUP_DIR}/initramfs/$(basename "$f")"
	else
		warn "expected initramfs image not found (will be created fresh): $f"
	fi
done

info "regenerating initramfs for $KVER only"
regen_initramfs "$DETECTED_INITRD_GEN" "$MKINITCPIO_PRESET"

# ---- 8. kernel cmdline (rootflags=data=ordered) ----------------------------

case "$CMDLINE_STEP" in
grub)
	cp -a /etc/default/grub "${BACKUP_DIR}/bootloader/grub.default.bak" 2>/dev/null || true
	cp -a "$DETECTED_GRUB_CFG" "${BACKUP_DIR}/bootloader/grub.cfg.bak" 2>/dev/null || true
	set_cmdline_grub "$DETECTED_GRUB_CFG" "$DETECTED_GRUB_MKCONFIG"
	;;
systemd-boot)
	cp -a "$DETECTED_SDBOOT_ENTRY" "${BACKUP_DIR}/bootloader/$(basename "$DETECTED_SDBOOT_ENTRY").bak" 2>/dev/null || true
	set_cmdline_systemd_boot "$DETECTED_SDBOOT_ENTRY"
	;;
manual)
	warn "cmdline step is manual - see the warning above; not modified automatically"
	;;
skip) : ;;
esac

# ---- 9. write state for uninstall.sh ---------------------------------------

cat >"${BACKUP_DIR}/state.env" <<EOF
# written by install.sh $(date -u +%Y-%m-%dT%H:%M:%SZ)
KVER="$KVER"
MOD_PATH="$STOCK_MOD"
MOD_COMPRESS="$DETECTED_MOD_COMPRESS"
INITRD_GEN="$DETECTED_INITRD_GEN"
MKINITCPIO_PRESET="$MKINITCPIO_PRESET"
CMDLINE_STEP="$CMDLINE_STEP"
GRUB_CFG="${DETECTED_GRUB_CFG:-}"
GRUB_MKCONFIG="${DETECTED_GRUB_MKCONFIG:-}"
SDBOOT_ENTRY="${DETECTED_SDBOOT_ENTRY:-}"
MODE="$DETECTED_MODE"
EOF
info "state written: ${BACKUP_DIR}/state.env"

# ---- 10. mode-specific finish ----------------------------------------------

if [ "$DETECTED_MODE" = "A" ]; then
	info "=== install staged. Reboot required (root is on nvme) - not rebooting automatically. ==="
	info "reboot into $KVER when ready; rescue kernel available: ${DETECTED_RESCUE_KVER:-<none, --force was used>}"
else
	info "root is not on nvme - attempting a live module reload (Mode B)."
	warn "Mode B live reload is implemented but UNVERIFIED end-to-end (our test hardware had root on nvme, so this path only ran detection there, not a real reload)."
	nvme_usage="$(lsmod | awk '$1=="nvme"{print $3}')"
	if [ -n "$nvme_usage" ] && [ "$nvme_usage" != "0" ]; then
		warn "nvme module is in use (lsmod usage count != 0) - not force-unloading."
		warn "Unmount/detach anything on other NVMe namespaces, then rerun, or rmmod/modprobe manually:"
		warn "  rmmod nvme && modprobe nvme"
	else
		info "rmmod nvme && modprobe nvme"
		if rmmod nvme 2>/tmp/gds-nvme-patch-rmmod.err; then
			modprobe nvme
			info "live reload done. Verify with: lsmod | grep nvme ; dmesg | tail"
		else
			warn "rmmod nvme failed: $(cat /tmp/gds-nvme-patch-rmmod.err 2>/dev/null)"
			warn "the new module is installed and will take effect on next boot/initramfs load regardless."
		fi
	fi
	info "=== install complete. Module + initramfs + cmdline updated; effective now (live) and persists across reboots. ==="
fi

# ---- 11. persistence (survive future kernel updates) -----------------------

if [ "$PERSIST" -eq 1 ]; then
	if [ -n "$PERSIST_FAMILY" ]; then
		install_persist "$PERSIST_FAMILY"
	else
		warn "--persist requested but no supported package manager (pacman/apt/dnf) was detected - skipping. See docs/PERSISTENCE.md to wire a hook manually for your distro."
	fi
else
	info "--no-persist: skipping kernel-update persistence hook install"
fi
