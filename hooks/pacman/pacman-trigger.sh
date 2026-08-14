#!/usr/bin/env bash
# pacman-trigger.sh - Exec target of /etc/pacman.d/hooks/gds-nvme-patch.hook.
# Runs as PostTransaction after any Install/Upgrade that touches
# usr/lib/modules/*/vmlinuz. Enumerates the kernel version(s) involved and
# reruns gds-nvme-rebuild for each - it internally no-ops for kernels with
# no headers or that are already patched, so calling it liberally is safe.
#
# FAIL-SAFE: this script must NEVER exit nonzero - a nonzero exit here would
# surface as a pacman hook failure and could abort/flag the whole
# transaction. Every step below swallows its own errors; the script always
# exits 0.
set -u

REPO="/usr/lib/gds-nvme-patch"
REBUILD="${REPO}/gds-nvme-rebuild"
LOG_DIR="/var/log/gds-nvme-patch"
mkdir -p "$LOG_DIR" 2>/dev/null || true

if [ ! -x "$REBUILD" ]; then
	printf '[gds-nvme-patch] %s not found or not executable, skipping\n' "$REBUILD" >&2
	exit 0
fi

# pacman feeds the matched Target paths (relative to /, e.g.
# "usr/lib/modules/7.1.6-1-cachyos/vmlinuz") on stdin because the hook sets
# NeedsTargets. Extract the kernel version component of each. If stdin is
# not readable/empty for any reason, fall back to a full scan of
# /usr/lib/modules - safe, since gds-nvme-rebuild independently gates each
# kernel on headers-present + not-already-patched, so scanning extra
# (unrelated, unchanged) kernels is a harmless no-op for them.
kvers=""
if [ ! -t 0 ]; then
	kvers="$(sed -n 's#^/*usr/lib/modules/\([^/]\{1,\}\)/vmlinuz$#\1#p' 2>/dev/null)"
fi
if [ -z "$kvers" ]; then
	for d in /usr/lib/modules/*/; do
		[ -f "${d}vmlinuz" ] || continue
		kvers="${kvers}$(basename "$d")
"
	done
fi

if [ -z "$kvers" ]; then
	printf '[gds-nvme-patch] no kernel modules trees found under /usr/lib/modules, nothing to do\n'
	exit 0
fi

printf '%s\n' "$kvers" | while IFS= read -r kver; do
	[ -n "$kver" ] || continue
	printf '[gds-nvme-patch] checking kernel %s\n' "$kver"
	"$REBUILD" "$kver" || printf '[gds-nvme-patch] %s: gds-nvme-rebuild itself failed unexpectedly (should not happen - it is meant to always exit 0)\n' "$kver" >&2
done

exit 0
