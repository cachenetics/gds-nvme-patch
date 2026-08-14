#!/usr/bin/env bash
# lib/build.sh - fetch, patch, and build the nvme.ko out-of-tree module.
# Sourced by install.sh. Depends on lib/detect.sh already being sourced
# (uses DETECTED_KDIR, DETECTED_TOOLCHAIN, DETECTED_KVER_BARE) and on the
# info/warn/err helpers defined in install.sh.

NVME_SRC_FILES=(pci.c core.c nvme.h fabrics.h trace.h)

# fetch_nvme_source <version-bare> <destdir>
# Pulls drivers/nvme/host/{pci.c,core.c,nvme.h,fabrics.h,trace.h} for tag
# v<version> from Greg KH's stable tree. Aborts (does not fall back to a
# different version) if the exact tag 404s - per spec, silently building
# against the wrong kernel source is worse than stopping.
fetch_nvme_source() {
	local ver="$1" dest="$2" f url http_code
	mkdir -p "$dest"
	for f in "${NVME_SRC_FILES[@]}"; do
		url="https://raw.githubusercontent.com/gregkh/linux/v${ver}/drivers/nvme/host/${f}"
		info "fetching ${f} (v${ver})"
		http_code="$(curl -sL -o "${dest}/${f}" -w '%{http_code}' "$url" || echo 000)"
		if [ "$http_code" != "200" ]; then
			err "fetch failed for ${f}: HTTP ${http_code} (${url})"
			err "tag v${ver} may not exist in the stable tree for this exact kernel version."
			err "stopping - refusing to silently substitute a different kernel's source."
			return 1
		fi
	done
	return 0
}

write_build_makefile() {
	local dest="$1"
	cat >"${dest}/Makefile" <<'EOF'
obj-m := nvme.o
nvme-y := pci.o
ccflags-y += -I$(src)
KDIR := /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF
}

# apply_nvme_patch <destdir> <repo-root>
# Runs the (unmodified, pre-existing) patcher. It asserts/refuses on any
# anchor mismatch - that behavior is never bypassed here.
apply_nvme_patch() {
	local dest="$1" repo_root="$2"
	( cd "$dest" && python3 "${repo_root}/lib/patch_nvme.py" pci.c )
}

# build_nvme_module <destdir> <toolchain>
build_nvme_module() {
	local dest="$1" toolchain="$2"
	( cd "$dest" && case "$toolchain" in
		clang) make LLVM=1 CC=clang ;;
		gcc)   make ;;
		*)     err "unknown toolchain '$toolchain'"; exit 1 ;;
	  esac )
}

# verify_vermagic <ko-path>
# Confirms the built module's vermagic matches the running kernel exactly.
verify_vermagic() {
	local ko="$1" got want
	command -v modinfo >/dev/null 2>&1 || { err "modinfo not found"; return 1; }
	got="$(modinfo -F vermagic "$ko" 2>/dev/null | awk '{print $1}')"
	want="$(uname -r)"
	if [ "$got" != "$want" ]; then
		err "vermagic mismatch: built module reports '$got', running kernel is '$want'"
		return 1
	fi
	return 0
}

# verify_nvfs_symbol <ko-path>
# Confirms the GDS registration entry point actually made it into the
# built object (sanity check that the patch + build did what we think).
# Captures nm's output into a variable and matches with a bash substring
# test rather than piping into `grep -q` - under `set -o pipefail`, `nm |
# grep -q pattern` can spuriously report failure: grep exits as soon as it
# finds a match and closes its end of the pipe, which can SIGPIPE nm before
# it finishes writing (nonzero exit), and pipefail then reports THAT as the
# pipeline's status even though grep's own match succeeded. Confirmed live
# on the oberon validation run.
verify_nvfs_symbol() {
	local ko="$1" out
	command -v nm >/dev/null 2>&1 || { warn "nm not found, skipping symbol check"; return 0; }
	out="$(nm "$ko" 2>/dev/null || true)"
	[[ "$out" == *"nvme_v2_register_nvfs_dma_ops"* ]]
}

# compress_module_like <src-ko> <format> <out-prefix>
# format is one of: none, zst, xz (see detect_module_compression).
# Writes <out-prefix>.ko[.zst|.xz] next to src-ko's directory and echoes the
# final path.
compress_module_like() {
	local src="$1" fmt="$2" out_prefix="$3" out
	case "$fmt" in
	none)
		out="${out_prefix}.ko"
		cp -f "$src" "$out"
		;;
	zst)
		command -v zstd >/dev/null 2>&1 || { err "zstd not found but installed module is .ko.zst"; return 1; }
		out="${out_prefix}.ko.zst"
		zstd -q -f -19 "$src" -o "$out"
		;;
	xz)
		command -v xz >/dev/null 2>&1 || { err "xz not found but installed module is .ko.xz"; return 1; }
		out="${out_prefix}.ko.xz"
		xz -f -k -9 -c "$src" >"$out"
		;;
	*)
		err "unknown compression format '$fmt'"
		return 1
		;;
	esac
	printf '%s\n' "$out"
}

# regen_initramfs <generator> <preset-or-empty>
regen_initramfs() {
	local gen="$1" preset="${2:-}"
	case "$gen" in
	mkinitcpio)
		[ -n "$preset" ] || { err "regen_initramfs: mkinitcpio needs a preset"; return 1; }
		mkinitcpio -p "$preset"
		;;
	dracut)
		dracut --force --kver "$(uname -r)"
		;;
	update-initramfs)
		update-initramfs -u -k "$(uname -r)"
		;;
	*)
		err "regen_initramfs: unknown generator '$gen'"
		return 1
		;;
	esac
}

# set_cmdline_grub <grub-cfg-path> <grub-mkconfig-bin>
# Idempotently adds rootflags=data=ordered to GRUB_CMDLINE_LINUX_DEFAULT in
# /etc/default/grub, then regenerates grub.cfg. Backs up /etc/default/grub
# first (caller is expected to have already backed it up; this is a second
# safety copy alongside the edit).
set_cmdline_grub() {
	local cfg_out="$1" mkconfig_bin="$2" defgrub="/etc/default/grub"
	[ -f "$defgrub" ] || { err "set_cmdline_grub: $defgrub not found"; return 1; }
	if grep -q 'rootflags=data=ordered' "$defgrub"; then
		info "grub cmdline already has rootflags=data=ordered, leaving as-is"
	else
		cp -f "$defgrub" "${defgrub}.gds-nvme-patch.bak"
		if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$defgrub"; then
			# insert before the closing quote of the existing value
			sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")([^"]*)"/\1\2 rootflags=data=ordered"/' "$defgrub"
		else
			printf 'GRUB_CMDLINE_LINUX_DEFAULT="rootflags=data=ordered"\n' >>"$defgrub"
		fi
	fi
	"$mkconfig_bin" -o "$cfg_out"
}

# set_cmdline_systemd_boot <entry-conf-path>
# Idempotently adds rootflags=data=ordered to the entry's "options" line.
set_cmdline_systemd_boot() {
	local entry="$1"
	[ -f "$entry" ] || { err "set_cmdline_systemd_boot: $entry not found"; return 1; }
	if grep -q 'rootflags=data=ordered' "$entry"; then
		info "systemd-boot entry already has rootflags=data=ordered, leaving as-is"
		return 0
	fi
	cp -f "$entry" "${entry}.gds-nvme-patch.bak"
	if grep -q '^options ' "$entry"; then
		sed -i -E 's/^options (.*)$/options \1 rootflags=data=ordered/' "$entry"
	else
		printf 'options rootflags=data=ordered\n' >>"$entry"
	fi
}
