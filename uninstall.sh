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
Usage: uninstall.sh [--dry-run] [-h|--help]

  --dry-run  Print what would be restored, touch nothing.
  -h, --help Show this help.

Restores the stock nvme module + initramfs (and bootloader cmdline edit, if
any) that install.sh backed up for the currently running kernel. Only ever
acts on the running kernel's backup - other installed kernels are untouched.
EOF
}

DRY_RUN=0
for a in "$@"; do
	case "$a" in
	--dry-run) DRY_RUN=1 ;;
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

KVER="$(uname -r)"
BACKUP_DIR="${STATE_DIR}/backups/${KVER}"
STATE_FILE="${BACKUP_DIR}/state.env"

[ -f "$STATE_FILE" ] || abort "no install state found for kernel $KVER at $STATE_FILE - nothing to uninstall (either never installed on this kernel, or already uninstalled)"

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
for f in "${BACKUP_DIR}"/initramfs/*; do
	dest="/boot/$(basename "$f")"
	info "restoring initramfs: $f -> $dest"
	cp -a "$f" "$dest"
done
shopt -u nullglob

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
	if [ -n "$nvme_usage" ] && [ "$nvme_usage" != "0" ]; then
		warn "nvme module is in use - not force-unloading. The stock module is installed and will load on next boot/reload."
	else
		info "rmmod nvme && modprobe nvme (reloading stock module live)"
		if rmmod nvme 2>/tmp/gds-nvme-patch-rmmod.err; then
			modprobe nvme
		else
			warn "rmmod nvme failed: $(cat /tmp/gds-nvme-patch-rmmod.err 2>/dev/null)"
			warn "the stock module is installed and will take effect on next boot regardless."
		fi
	fi
fi

# mark this backup as consumed, but keep the files around (harmless, and lets
# a repeat run / manual recovery still find them).
mv "$STATE_FILE" "${STATE_FILE}.uninstalled-$(date -u +%Y%m%dT%H%M%SZ)"

info "=== uninstall complete. Stock nvme module + initramfs restored for kernel $KVER. ==="
[ "${MODE:-}" = "A" ] && info "reboot to fully return to the stock module if you rebooted into the patched one."
