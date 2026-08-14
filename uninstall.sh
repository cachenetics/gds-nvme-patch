#!/usr/bin/env bash
# uninstall.sh - restore the stock nvme module, initramfs, and any bootloader
# cmdline edit made by install.sh for the CURRENT kernel. Never touches any
# other installed kernel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/gds-nvme-patch"

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
err()  { printf '[err ] %s\n' "$*" >&2; }
abort() { err "$*"; exit 1; }

usage() {
	cat <<'EOF'
Usage: uninstall.sh [--dry-run] [--purge] [-h|--help]

  --dry-run  Print what would be restored/removed, touch nothing.
  --purge    Also delete this kernel's backup dir under
             /var/lib/gds-nvme-patch/backups/ (module/initramfs/bootloader
             backups + state.env) once the restore is done. Without this,
             backups are left in place (harmless, lets you reinstall later
             or recover manually).
  -h, --help Show this help.

Restores the stock nvme module + initramfs (and bootloader cmdline edit, if
any) that install.sh (or a kernel-update rebuild hook) backed up for the
currently running kernel - only ever acts on the running kernel's backup,
other installed kernels are untouched. Also removes any kernel-update
persistence hook (pacman/apt/dnf) and the /usr/lib/gds-nvme-patch/ tool copy
that `install.sh --persist` installed - that part is host-wide and runs
regardless of whether the running kernel has a backup to restore.
EOF
}

DRY_RUN=0
PURGE=0
for a in "$@"; do
	case "$a" in
	--dry-run) DRY_RUN=1 ;;
	--purge) PURGE=1 ;;
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

if [ "$(id -u)" -ne 0 ]; then
	abort "must be run as root (sudo ./uninstall.sh ${*})"
fi

# ---- persistence removal (hooks + stable tool copy) ------------------------
# Host-wide, independent of whether the CURRENTLY RUNNING kernel has install
# state - runs (or is reported, under --dry-run) regardless, before the
# per-kernel restore below (which can still abort if this kernel has nothing
# to restore).
PERSIST_TARGETS=(
	/etc/pacman.d/hooks/gds-nvme-patch.hook
	/etc/kernel/postinst.d/zz-gds-nvme-patch
	/etc/kernel/install.d/95-gds-nvme-patch.install
	/usr/lib/gds-nvme-patch
)
persist_found=0
for t in "${PERSIST_TARGETS[@]}"; do
	[ -e "$t" ] || continue
	persist_found=1
	if [ "$DRY_RUN" -eq 1 ]; then
		info "would remove: $t"
	else
		info "removing: $t"
		rm -rf "$t"
	fi
done
[ "$persist_found" -eq 1 ] || info "no persistence hook/tool copy found (nothing to remove there)"

# ---- per-kernel module/initramfs/cmdline restore (existing behavior) -------

KVER="$(uname -r)"
BACKUP_DIR="${STATE_DIR}/backups/${KVER}"
STATE_FILE="${BACKUP_DIR}/state.env"

[ -f "$STATE_FILE" ] || abort "no install state found for kernel $KVER at $STATE_FILE - nothing to restore for THIS kernel (either it was never patched, or it was already uninstalled). Any persistence hook/tool copy was already handled above."

# shellcheck source=/dev/null
. "$STATE_FILE"

info "=== gds-nvme-patch uninstaller (kernel $KVER) ==="
info "restoring from: $BACKUP_DIR"

STOCK_MOD_BACKUP="${BACKUP_DIR}/module/$(basename "$MOD_PATH")"
[ -f "$STOCK_MOD_BACKUP" ] || abort "expected backup module not found: $STOCK_MOD_BACKUP"

if [ "$DRY_RUN" -eq 1 ]; then
	info "would restore module:    $STOCK_MOD_BACKUP -> $MOD_PATH"
	for f in "${BACKUP_DIR}"/initramfs/*; do
		[ -e "$f" ] || continue
		info "would restore initramfs: $f -> /boot/$(basename "$f")"
	done
	case "$CMDLINE_STEP" in
	grub) info "would restore grub cmdline files from ${BACKUP_DIR}/bootloader/" ;;
	systemd-boot) info "would restore systemd-boot entry from ${BACKUP_DIR}/bootloader/" ;;
	*) info "no cmdline changes to restore (cmdline step was '$CMDLINE_STEP' at install time)" ;;
	esac
	info "would run: depmod -a $KVER"
	if [ "$PURGE" -eq 1 ]; then
		info "--purge: would remove backup dir $BACKUP_DIR"
	else
		info "would mark $STATE_FILE as consumed (backup dir $BACKUP_DIR left in place; use --purge to remove it)"
	fi
	info "--dry-run: nothing touched."
	exit 0
fi

# ---- module ----

info "restoring stock module: $STOCK_MOD_BACKUP -> $MOD_PATH"
install -m 0644 "$STOCK_MOD_BACKUP" "$MOD_PATH"

info "depmod -a"
depmod -a "$KVER"

# ---- initramfs ----

shopt -s nullglob
initramfs_restored=0
for f in "${BACKUP_DIR}"/initramfs/*; do
	dest="/boot/$(basename "$f")"
	info "restoring initramfs: $f -> $dest"
	cp -a "$f" "$dest"
	initramfs_restored=1
done
shopt -u nullglob

# Belt-and-suspenders: an OLD backup dir (from before initramfs backups were
# added to lib/rebuild.sh) can have the module backup but no initramfs/
# contents. Rather than leave the patched module embedded in an unregenerated
# initramfs, regenerate it directly from the just-restored stock module,
# using the generator recorded for this kernel at install/rebuild time.
if [ "$initramfs_restored" -eq 0 ]; then
	warn "no initramfs backup found under ${BACKUP_DIR}/initramfs/ - the stock module is restored on disk, but the initramfs may still embed the patched module until it is regenerated."
	if [ -n "${INITRD_GEN:-}" ] && [ -f "$SCRIPT_DIR/lib/detect.sh" ] && [ -f "$SCRIPT_DIR/lib/build.sh" ]; then
		info "falling back to regenerating the initramfs directly ($INITRD_GEN) so it matches the restored stock module"
		# shellcheck source=lib/detect.sh
		. "$SCRIPT_DIR/lib/detect.sh"
		# shellcheck source=lib/build.sh
		. "$SCRIPT_DIR/lib/build.sh"
		if regen_initramfs "$INITRD_GEN" "${MKINITCPIO_PRESET:-}"; then
			info "initramfs regenerated for $KVER - now matches the restored stock module"
		else
			warn "initramfs regeneration failed - regenerate it manually (mkinitcpio -p <preset> / dracut --force --kver $KVER / update-initramfs -u -k $KVER) before rebooting into $KVER, or the patched module may still be embedded"
		fi
	elif [ -z "${INITRD_GEN:-}" ]; then
		warn "no INITRD_GEN recorded in this kernel's state.env either - regenerate the initramfs manually before rebooting into $KVER"
	else
		warn "could not find lib/detect.sh + lib/build.sh next to this script ($SCRIPT_DIR/lib) - regenerate the initramfs manually (e.g. mkinitcpio -p <preset> / dracut --force / update-initramfs -u) before rebooting into $KVER"
	fi
fi

# ---- bootloader cmdline ----

case "$CMDLINE_STEP" in
grub)
	if [ -f "${BACKUP_DIR}/bootloader/grub.default.bak" ]; then
		info "restoring /etc/default/grub"
		cp -a "${BACKUP_DIR}/bootloader/grub.default.bak" /etc/default/grub
	fi
	if [ -n "${GRUB_CFG:-}" ] && [ -f "${BACKUP_DIR}/bootloader/grub.cfg.bak" ]; then
		info "restoring $GRUB_CFG"
		cp -a "${BACKUP_DIR}/bootloader/grub.cfg.bak" "$GRUB_CFG"
	fi
	;;
systemd-boot)
	if [ -n "${SDBOOT_ENTRY:-}" ]; then
		bak="${BACKUP_DIR}/bootloader/$(basename "$SDBOOT_ENTRY").bak"
		if [ -f "$bak" ]; then
			info "restoring $SDBOOT_ENTRY"
			cp -a "$bak" "$SDBOOT_ENTRY"
		fi
	fi
	;;
manual)
	warn "cmdline step was 'manual' at install time - if you added rootflags=data=ordered by hand, remove it yourself."
	;;
skip) : ;;
esac

# ---- live reload for Mode B ----

if [ "${MODE:-}" = "B" ]; then
	nvme_usage="$(lsmod | awk '$1=="nvme"{print $3}')"
	if [ -z "$nvme_usage" ]; then
		info "nvme module is not currently loaded - modprobe nvme"
		modprobe nvme
	elif [ "$nvme_usage" != "0" ]; then
		warn "nvme module is in use - not force-unloading. The stock module is installed and will load on next boot/reload."
	else
		info "rmmod nvme && modprobe nvme (reloading stock module live)"
		err_f=""
		err_f="$(mktemp 2>/dev/null)" || err_f=""
		if rmmod nvme 2>"${err_f:-/dev/null}"; then
			modprobe nvme
		else
			if [ -n "$err_f" ]; then
				warn "rmmod nvme failed: $(cat "$err_f" 2>/dev/null)"
			else
				warn "rmmod nvme failed (could not capture stderr - mktemp failed)"
			fi
			warn "the stock module is installed and will take effect on next boot regardless."
		fi
		[ -n "$err_f" ] && rm -f "$err_f"
	fi
fi

if [ "$PURGE" -eq 1 ]; then
	info "--purge: removing backup dir $BACKUP_DIR"
	rm -rf "$BACKUP_DIR"
else
	# mark this backup as consumed, but keep the files around (harmless, and
	# lets a repeat run / manual recovery still find them).
	mv "$STATE_FILE" "${STATE_FILE}.uninstalled-$(date -u +%Y%m%dT%H%M%SZ)"
fi

# ---- other still-patched kernels ----
# This script only ever reverts the RUNNING kernel - warn if other installed
# kernels (patched by install.sh directly, or by a kernel-update rebuild
# hook) still have the patch installed, so that is never silently assumed
# fixed too.
other_backups=()
for d in "${STATE_DIR}/backups"/*/; do
	[ -d "$d" ] || continue
	other_kver="$(basename "$d")"
	[ "$other_kver" = "$KVER" ] && continue
	# a live (not yet uninstalled) backup still has state.env; one already
	# uninstalled was renamed to state.env.uninstalled-* above - skip those.
	[ -f "${d}state.env" ] || continue
	other_backups+=("$other_kver")
done

if [ "${#other_backups[@]}" -gt 0 ]; then
	warn "${#other_backups[@]} other kernel(s) still have the patch installed: ${other_backups[*]}. Boot into each and rerun uninstall.sh to revert them (or use --purge to also drop their backups)."
	if [ "$PURGE" -eq 1 ]; then
		for k in "${other_backups[@]}"; do
			info "--purge: removing backup dir ${STATE_DIR}/backups/${k} (this only drops the backup - kernel $k's own nvme module/initramfs are NOT reverted; boot into it and rerun uninstall.sh, or reinstall, if you still need a rollback path there)"
			rm -rf "${STATE_DIR}/backups/${k}"
		done
	fi
fi

info "=== uninstall complete. Stock nvme module + initramfs restored for kernel $KVER. ==="
[ "${MODE:-}" = "A" ] && info "reboot to fully return to the stock module if you rebooted into the patched one."
