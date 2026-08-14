#!/usr/bin/env bash
# lib/rebuild.sh - fail-safe rebuild of the patched nvme module for ONE
# specific kernel version, not necessarily the one this process is running
# under. This is what makes the patch survive a kernel update: the
# persistence hooks (hooks/{pacman,debian,fedora}/...) call the
# gds-nvme-rebuild CLI wrapper, which sources this file and calls
# gds_rebuild_kernel <KVER> for each newly-installed kernel.
#
# Depends on lib/detect.sh and lib/build.sh already being sourced (uses
# detect_*/get_nvme_source/apply_nvme_patch/build_nvme_module/verify_*/
# compress_module_like/regen_initramfs - see those files). Sets GDS_KVER
# itself before calling into them, so the SAME detection/build code that
# install.sh runs for the running kernel runs here for an arbitrary one.
#
# CONTRACT: gds_rebuild_kernel ALWAYS returns 0. This runs unattended inside
# a package manager transaction (pacman/apt/dnf) - it must never fail that
# transaction. On any doubt about a given kernel, it leaves that kernel's
# stock nvme module untouched and logs why, rather than risk installing a
# broken or mismatched module. It never touches the bootloader cmdline
# (rootflags=data=ordered is set once at first install and persists via the
# shared grub.cfg / the systemd-boot entry install.sh already edited).

GDS_REBUILD_STATE_DIR="${GDS_REBUILD_STATE_DIR:-/var/lib/gds-nvme-patch}"
GDS_REBUILD_LOG_DIR="${GDS_REBUILD_LOG_DIR:-/var/log/gds-nvme-patch}"
# Where lib/patch_nvme.py (and this file's siblings) live. The persisted
# copy --persist installs is /usr/lib/gds-nvme-patch; the gds-nvme-rebuild
# CLI wrapper sets this to its own directory before calling in. Falls back
# to the persisted location if unset (e.g. this file sourced directly).
GDS_REBUILD_REPO_ROOT="${GDS_REBUILD_REPO_ROOT:-/usr/lib/gds-nvme-patch}"

# info/warn/err: reuse the caller's (install.sh, the gds-nvme-rebuild CLI
# wrapper) if already defined, else define minimal fallbacks so this file
# is self-contained when sourced/tested on its own.
if ! declare -F info >/dev/null 2>&1; then
	info() { printf '[info] %s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
	warn() { printf '[warn] %s\n' "$*" >&2; }
fi
if ! declare -F err >/dev/null 2>&1; then
	err() { printf '[err ] %s\n' "$*" >&2; }
fi

# _gds_module_has_nvfs_symbol <module-path>
# True if the (possibly compressed) installed module already exports
# nvme_v2_register_nvfs_dma_ops, i.e. it is already patched. Decompresses to
# a scratch file first if needed (nm can't read .zst/.xz directly). If we
# can't determine it (nm/decompressor missing), returns false (not patched)
# - the normal build-and-verify path below is the safe fallback either way.
_gds_module_has_nvfs_symbol() {
	local mod="$1" tmp="" out
	case "$mod" in
	*.zst)
		command -v zstd >/dev/null 2>&1 || return 1
		tmp="$(mktemp)" || return 1
		zstd -dq -f "$mod" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
		;;
	*.xz)
		command -v xz >/dev/null 2>&1 || return 1
		tmp="$(mktemp)" || return 1
		xz -dc "$mod" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
		;;
	*)
		tmp="$mod"
		;;
	esac
	command -v nm >/dev/null 2>&1 || { [ "$tmp" != "$mod" ] && rm -f "$tmp"; return 1; }
	out="$(nm "$tmp" 2>/dev/null || true)"
	[ "$tmp" != "$mod" ] && rm -f "$tmp"
	[[ "$out" == *"nvme_v2_register_nvfs_dma_ops"* ]]
}

# _gds_rebuild_inner <kver>
# Does the actual work. Every exit path is `return 0` with a final line
# `SUMMARY: <kver>: <status>` - gds_rebuild_kernel below extracts that line
# as the one-line summary and logs everything else to file. Deliberately no
# `set -e` in this file: every risky step is checked explicitly with
# `if ! step; then ... return 0; fi` so a failure anywhere falls through to
# "leave stock" instead of aborting.
_gds_rebuild_inner() {
	local kver="$1"
	info "=== gds-nvme-rebuild check: kernel $kver ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="

	if [ "$(uname -m)" != "x86_64" ]; then
		warn "$kver: host arch $(uname -m) is not x86_64, leaving stock"
		echo "SUMMARY: $kver: skipped (unsupported arch)"
		return 0
	fi

	local kdir="/lib/modules/${kver}/build"
	if [ ! -d "$kdir" ] || [ ! -f "$kdir/Makefile" ]; then
		info "no headers for $kver, skipping"
		echo "SUMMARY: $kver: skipped (no headers)"
		return 0
	fi

	local mod_dir="/lib/modules/${kver}/kernel/drivers/nvme/host" installed_mod="" ext
	for ext in "" .zst .xz; do
		if [ -f "${mod_dir}/nvme.ko${ext}" ]; then
			installed_mod="${mod_dir}/nvme.ko${ext}"
			break
		fi
	done
	if [ -z "$installed_mod" ]; then
		warn "$kver: no installed nvme.ko(.zst|.xz) found under $mod_dir, skipping"
		echo "SUMMARY: $kver: skipped (no installed nvme module found)"
		return 0
	fi

	if _gds_module_has_nvfs_symbol "$installed_mod"; then
		info "$kver: already patched (nvme_v2 symbol present in $installed_mod), skipping"
		echo "SUMMARY: $kver: skipped (already patched)"
		return 0
	fi

	# From here on every detect_*/build.sh call targets $kver, not
	# whatever kernel this process happens to be running under.
	export GDS_KVER="$kver"

	if ! detect_kernel_release; then
		warn "$kver: could not parse an X.Y.Z release out of the kernel version, leaving stock"
		echo "SUMMARY: $kver: left stock (bad kernel version format)"
		return 0
	fi

	detect_toolchain

	if ! detect_module_compression; then
		warn "$kver: could not determine installed nvme module compression, leaving stock"
		echo "SUMMARY: $kver: left stock (compression detect failed)"
		return 0
	fi

	if ! detect_initramfs_generator; then
		warn "$kver: no supported initramfs generator found, leaving stock"
		echo "SUMMARY: $kver: left stock (no initramfs generator)"
		return 0
	fi

	local mkinitcpio_preset=""
	if [ "$DETECTED_INITRD_GEN" = "mkinitcpio" ]; then
		if ! detect_mkinitcpio_preset; then
			warn "$kver: could not resolve an mkinitcpio preset for this kernel, leaving stock"
			echo "SUMMARY: $kver: left stock (no mkinitcpio preset match)"
			return 0
		fi
		mkinitcpio_preset="$DETECTED_MKINITCPIO_PRESET"
	fi

	local workdir
	workdir="$(mktemp -d /tmp/gds-nvme-rebuild.XXXXXX)" || {
		err "$kver: mktemp failed, leaving stock"
		echo "SUMMARY: $kver: left stock (mktemp failed)"
		return 0
	}
	_gds_rebuild_cleanup_workdir() { rm -rf "$workdir"; }
	trap _gds_rebuild_cleanup_workdir RETURN

	info "$kver: fetching nvme source for v${DETECTED_KVER_BARE}"
	if ! get_nvme_source "$DETECTED_KVER_BARE" "$workdir" ""; then
		warn "$kver: kernel source acquisition failed, leaving stock"
		echo "SUMMARY: $kver: left stock (source fetch failed)"
		return 0
	fi

	if ! detect_nvme_api_era "$workdir/pci.c"; then
		warn "$kver: nvme driver uses the legacy pre-6.18 DMA API, unsupported by this patch - leaving stock"
		echo "SUMMARY: $kver: left stock (legacy nvme API, unsupported)"
		return 0
	fi

	write_build_makefile "$workdir"

	info "$kver: applying patch"
	if ! apply_nvme_patch "$workdir" "$GDS_REBUILD_REPO_ROOT"; then
		warn "$kver: patcher refused - this kernel's pci.c layout does not match the patch's anchors (expected/safe for an unsupported kernel shape, e.g. 6.17/6.18). Leaving stock nvme.ko untouched."
		echo "SUMMARY: $kver: left stock (patch refused - unsupported kernel shape)"
		return 0
	fi

	info "$kver: building nvme.ko ($DETECTED_TOOLCHAIN)"
	if ! build_nvme_module "$workdir" "$DETECTED_TOOLCHAIN"; then
		warn "$kver: build failed, leaving stock"
		echo "SUMMARY: $kver: left stock (build failed)"
		return 0
	fi

	local ko="$workdir/nvme.ko"
	if [ ! -f "$ko" ]; then
		warn "$kver: build reported success but $ko is missing, leaving stock"
		echo "SUMMARY: $kver: left stock (missing build output)"
		return 0
	fi

	if ! verify_vermagic "$ko"; then
		warn "$kver: vermagic mismatch, leaving stock (refusing to install a module that won't load)"
		echo "SUMMARY: $kver: left stock (vermagic mismatch)"
		return 0
	fi

	if ! verify_nvfs_symbol "$ko"; then
		warn "$kver: built module is missing nvme_v2_register_nvfs_dma_ops, leaving stock"
		echo "SUMMARY: $kver: left stock (symbol verification failed)"
		return 0
	fi

	info "$kver: patch built and verified - installing"

	local backup_dir="${GDS_REBUILD_STATE_DIR}/backups/${kver}"
	if ! mkdir -p "${backup_dir}/module" 2>/dev/null; then
		warn "$kver: could not create backup dir $backup_dir, leaving stock (refusing to install without a backup)"
		echo "SUMMARY: $kver: left stock (backup dir creation failed)"
		return 0
	fi

	local backup_target="${backup_dir}/module/$(basename "$installed_mod")"
	if [ -f "$backup_target" ]; then
		info "$kver: stock module already backed up at $backup_target"
	else
		if ! cp -a "$installed_mod" "$backup_target"; then
			warn "$kver: failed to back up the stock module, leaving stock (refusing to install without a backup)"
			echo "SUMMARY: $kver: left stock (backup copy failed)"
			return 0
		fi
	fi

	local new_mod
	new_mod="$(compress_module_like "$ko" "$DETECTED_MOD_COMPRESS" "${workdir}/nvme-patched")"
	if [ -z "$new_mod" ] || [ ! -f "$new_mod" ]; then
		warn "$kver: module compression step failed, leaving stock"
		echo "SUMMARY: $kver: left stock (compression failed)"
		return 0
	fi

	if ! install -m 0644 "$new_mod" "$installed_mod"; then
		warn "$kver: failed to install the patched module, leaving stock (module on disk unchanged)"
		echo "SUMMARY: $kver: left stock (install copy failed)"
		return 0
	fi

	if ! depmod -a "$kver"; then
		warn "$kver: depmod failed AFTER installing the patched module - module may not resolve correctly, check manually"
		echo "SUMMARY: $kver: patched module installed but depmod FAILED - check manually"
		return 0
	fi

	info "$kver: regenerating initramfs ($DETECTED_INITRD_GEN)"
	if ! regen_initramfs "$DETECTED_INITRD_GEN" "$mkinitcpio_preset"; then
		warn "$kver: initramfs regeneration failed - the module is installed but the initramfs may still embed the stock one, check manually"
		echo "SUMMARY: $kver: patched module installed but initramfs regen FAILED - check manually"
		return 0
	fi

	# Record state so uninstall.sh works on this kernel too, not just one
	# installed directly by install.sh. CMDLINE_STEP=skip / the bootloader
	# fields are blank on purpose - this path never touches cmdline, and
	# MODE is blank so uninstall.sh's live-reload section (Mode B) never
	# fires for a kernel that is not the one currently running.
	{
		printf '# written by gds-nvme-rebuild (kernel update hook) %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'KVER="%s"\n' "$kver"
		printf 'MOD_PATH="%s"\n' "$installed_mod"
		printf 'MOD_COMPRESS="%s"\n' "$DETECTED_MOD_COMPRESS"
		printf 'INITRD_GEN="%s"\n' "$DETECTED_INITRD_GEN"
		printf 'MKINITCPIO_PRESET="%s"\n' "$mkinitcpio_preset"
		printf 'CMDLINE_STEP="skip"\n'
		printf 'GRUB_CFG=""\n'
		printf 'GRUB_MKCONFIG=""\n'
		printf 'SDBOOT_ENTRY=""\n'
		printf 'MODE=""\n'
	} >"${backup_dir}/state.env" 2>/dev/null || warn "$kver: could not write ${backup_dir}/state.env (uninstall.sh will not find this kernel later; module/initramfs are still correctly installed)"

	info "$kver: rebuild complete - patched nvme.ko installed, initramfs regenerated"
	echo "SUMMARY: $kver: patched and installed OK"
	return 0
}

# gds_rebuild_kernel <kver>
# Public entry point. See the file header for the fail-safe contract: this
# ALWAYS returns 0 and prints exactly one summary line to stdout, regardless
# of what happened inside. Full detail goes to
# $GDS_REBUILD_LOG_DIR/rebuild-<kver>.log.
gds_rebuild_kernel() {
	local kver="${1:-}"
	if [ -z "$kver" ]; then
		err "gds_rebuild_kernel: kernel version required"
		echo "SUMMARY: (unknown): skipped (no kernel version given)"
		return 0
	fi

	mkdir -p "$GDS_REBUILD_LOG_DIR" 2>/dev/null || true
	local log="${GDS_REBUILD_LOG_DIR}/rebuild-${kver}.log"

	local out summary
	out="$(_gds_rebuild_inner "$kver" 2>&1)"
	printf '%s\n' "$out" >>"$log" 2>/dev/null || true

	summary="$(printf '%s\n' "$out" | grep '^SUMMARY:' | tail -n1)"
	[ -n "$summary" ] || summary="SUMMARY: $kver: rebuild check ended without a summary line - see $log"
	printf '%s\n' "$summary"
	return 0
}
