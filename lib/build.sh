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
# Copy the needed nvme host sources from a local kernel source tree.
_copy_nvme_from_dir() {
	local srcroot="$1" dest="$2" hostdir f
	hostdir="${srcroot%/}/drivers/nvme/host"
	[ -f "${hostdir}/pci.c" ] || { err "no drivers/nvme/host/pci.c under '${srcroot}'"; return 1; }
	mkdir -p "$dest"
	for f in "${NVME_SRC_FILES[@]}"; do
		if [ -f "${hostdir}/${f}" ]; then
			cp -f "${hostdir}/${f}" "${dest}/${f}"
		else
			warn "note: ${f} not in local source tree (may be fine; pci.c is the one that matters)"
		fi
	done
	return 0
}

# Auto-detect a local kernel source tree that carries the .c files (not just
# headers), for the target kernel ($GDS_KVER). Common on distros that ship a
# linux-source package or a source symlink. Echoes the path, or nothing.
_find_local_nvme_source() {
	local kver cand
	kver="$GDS_KVER"
	for cand in \
		"/lib/modules/${kver}/source" \
		"/lib/modules/${kver}/build" \
		/usr/src/linux-source-*/ \
		/usr/src/linux-headers-"${kver}" \
		"/usr/src/linux-${kver}" \
		/usr/src/linux; do
		[ -f "${cand%/}/drivers/nvme/host/pci.c" ] && { printf '%s\n' "${cand%/}"; return 0; }
	done
	return 1
}

# Fetch the nvme host sources from the mainline stable tree, trying tag
# candidates so a distro version like "7.0.0" maps to the real tag "v7.0".
_fetch_nvme_from_mainline() {
	local ver="$1" dest="$2" f url http_code tag tags mm
	mkdir -p "$dest"
	# candidate tags, most-specific first
	tags="v${ver}"
	mm="$(printf '%s' "$ver" | grep -oE '^[0-9]+\.[0-9]+')"
	# a X.Y.0 release is tagged vX.Y (no trailing .0) in the git tree
	case "$ver" in
	*.0) tags="${tags} v${mm}" ;;
	esac
	tag=""
	for t in $tags; do
		http_code="$(curl -sL -o "${dest}/pci.c" -w '%{http_code}' \
			"https://raw.githubusercontent.com/gregkh/linux/${t}/drivers/nvme/host/pci.c" 2>/dev/null || echo 000)"
		if [ "$http_code" = "200" ]; then tag="$t"; break; fi
	done
	if [ -z "$tag" ]; then
		err "could not find a stable-tree tag for kernel ${ver} (tried: ${tags})."
		err "Point the installer at your distro's own kernel source instead:"
		err "  --src-dir=/path/to/linux-source   (e.g. apt-get source linux, or dnf's kernel-devel tree)"
		err "Refusing to silently substitute a different kernel's source."
		return 1
	fi
	info "using mainline stable tag ${tag} for kernel ${ver}"
	for f in "${NVME_SRC_FILES[@]}"; do
		[ "$f" = "pci.c" ] && continue
		http_code="$(curl -sL -o "${dest}/${f}" -w '%{http_code}' \
			"https://raw.githubusercontent.com/gregkh/linux/${tag}/drivers/nvme/host/${f}" 2>/dev/null || echo 000)"
		[ "$http_code" = "200" ] || warn "note: ${f} not at ${tag} (continuing; pci.c is what matters)"
	done
	return 0
}

# Distro-friendly source acquisition:
#   1. explicit --src-dir (use the distro's exact source - most robust),
#   2. an auto-detected local kernel source tree,
#   3. mainline stable tree with version-tag normalization.
# If the mainline pci.c does not match your distro's patched nvme driver, the
# patcher refuses (safely); use --src-dir with your distro source to fix that.
get_nvme_source() {
	local ver="$1" dest="$2" src_dir="${3:-}" local_src
	if [ -n "$src_dir" ]; then
		info "using kernel source from --src-dir: $src_dir"
		_copy_nvme_from_dir "$src_dir" "$dest" || return 1
		return 0
	fi
	if local_src="$(_find_local_nvme_source)"; then
		info "using local kernel source tree: $local_src"
		_copy_nvme_from_dir "$local_src" "$dest" || return 1
		return 0
	fi
	info "no local kernel source found; fetching from mainline stable tree"
	_fetch_nvme_from_mainline "$ver" "$dest" || return 1
	return 0
}

# back-compat alias (older call sites)
fetch_nvme_source() { get_nvme_source "$1" "$2" "${3:-}"; }

write_build_makefile() {
	local dest="$1"
	# KDIR is the TARGET kernel's headers ($GDS_KVER, the running kernel
	# unless overridden) - baked in literally rather than left as
	# `$(shell uname -r)`, because when lib/rebuild.sh builds for a kernel
	# other than the one currently running, `uname -r` at make-time would
	# resolve to the wrong (running) kernel. The heredoc is intentionally
	# unquoted so $GDS_KVER expands now; make's own $(MAKE)/$(KDIR)/$(PWD)
	# are backslash-escaped so make sees them literally.
	cat >"${dest}/Makefile" <<EOF
obj-m := nvme.o
nvme-y := pci.o
ccflags-y += -I\$(src)
KDIR := /lib/modules/${GDS_KVER}/build
all:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) modules
clean:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) clean
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
# Confirms the built module's vermagic matches the target kernel ($GDS_KVER,
# the running kernel unless overridden) exactly.
verify_vermagic() {
	local ko="$1" got want
	command -v modinfo >/dev/null 2>&1 || { err "modinfo not found"; return 1; }
	got="$(modinfo -F vermagic "$ko" 2>/dev/null | awk '{print $1}')"
	want="$GDS_KVER"
	if [ "$got" != "$want" ]; then
		err "vermagic mismatch: built module reports '$got', target kernel is '$want'"
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
# during validation.
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
# Regenerates for the target kernel ($GDS_KVER, the running kernel unless
# overridden). mkinitcpio presets already resolve to a specific kernel's
# image paths (see detect_mkinitcpio_preset), so only dracut/update-initramfs
# need an explicit kernel version.
regen_initramfs() {
	local gen="$1" preset="${2:-}"
	case "$gen" in
	mkinitcpio)
		[ -n "$preset" ] || { err "regen_initramfs: mkinitcpio needs a preset"; return 1; }
		mkinitcpio -p "$preset"
		;;
	dracut)
		dracut --force --kver "$GDS_KVER"
		;;
	update-initramfs)
		update-initramfs -u -k "$GDS_KVER"
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
