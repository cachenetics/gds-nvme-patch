#!/usr/bin/env bash
# probe.sh - READ-ONLY pre-flight check for gds-nvme-patch.
#
# Run this FIRST, before install.sh. It touches nothing on your system (no
# modules, no initramfs, no bootloader; it only reads state and may fetch a
# copy of your kernel's nvme source into /tmp to test-apply the patch). It
# prints what we need to know to tell you whether GDS will work on your box.
#
#   bash probe.sh              # full report
#   bash probe.sh | tee gds-probe.txt   # and save it to send back
#
# sudo is NOT required, but a few checks (full lspci topology, dmesg) are richer
# with it; run `sudo bash probe.sh` for the complete picture.
set -u

ok(){   printf '  [ok]   %s\n' "$*"; }
warn(){ printf '  [warn] %s\n' "$*"; }
bad(){  printf '  [FAIL] %s\n' "$*"; }
note(){ printf '         %s\n' "$*"; }
hdr(){  printf '\n=== %s ===\n' "$*"; }

VERDICT_BLOCKERS=()
VERDICT_WARN=()

hdr "1. System"
if [ -r /etc/os-release ]; then . /etc/os-release; note "distro: ${PRETTY_NAME:-unknown}"; fi
KVER="$(uname -r)"; ARCH="$(uname -m)"
note "kernel: $KVER   arch: $ARCH"
[ "$ARCH" = "x86_64" ] && ok "x86_64" || { bad "arch $ARCH not supported (x86_64 only)"; VERDICT_BLOCKERS+=("arch"); }
BARE="$(printf '%s' "$KVER" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
MAJ="$(printf '%s' "$BARE" | cut -d. -f1)"; MIN="$(printf '%s' "$BARE" | cut -d. -f2)"
if [ -n "$MAJ" ] && { [ "$MAJ" -gt 7 ] || { [ "$MAJ" -eq 7 ]; } || { [ "$MAJ" -eq 6 ] && [ "$MIN" -ge 18 ]; }; }; then
	ok "kernel $BARE is in the iterator-API era (>=6.18)"
	case "$BARE" in
	7.0*|7.1*) ok "kernel $BARE matches a layout the patch is known to apply to (7.0 / 7.1)";;
	6.18*|6.17*) warn "kernel $BARE: iterator API but a different code shape; the patch currently REFUSES on 6.17/6.18 (anchors TODO)"; VERDICT_WARN+=("kernel-6.18-shape");;
	*) warn "kernel $BARE: iterator era but untested layout - patch may or may not apply (the applicability test below is authoritative)";;
	esac
else
	bad "kernel $BARE is pre-6.18 (legacy nvme API) - use NVIDIA's MOFED/DOCA nvme patch, not this one"
	VERDICT_BLOCKERS+=("kernel-too-old")
fi
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
case "$ROOT_SRC" in
/dev/nvme*) note "root fs: $ROOT_SRC (on NVMe) -> Mode A: install needs a reboot; keep a rescue kernel"; ONNVME=1;;
*) note "root fs: ${ROOT_SRC:-unknown} (not on NVMe) -> Mode B possible: live reload, no reboot"; ONNVME=0;;
esac
note "root fs type: $(findmnt -no FSTYPE / 2>/dev/null || echo unknown) (ext4 needs rootflags=data=ordered)"
RESCUE=0
for m in /lib/modules/*/; do k="$(basename "$m")"; [ "$k" = "$KVER" ] && continue; [ -e "${m}kernel/drivers/nvme/host/nvme.ko" ] || [ -e "${m}kernel/drivers/nvme/host/nvme.ko.zst" ] || [ -e "${m}kernel/drivers/nvme/host/nvme.ko.xz" ] && { RESCUE=1; note "rescue kernel present: $k"; }; done
[ "$ONNVME" = "1" ] && { [ "$RESCUE" = "1" ] && ok "a second (rescue) kernel is installed" || { warn "NO second kernel installed - risky for Mode A (no fallback if a build is bad). Install a second kernel first."; VERDICT_WARN+=("no-rescue"); }; }

hdr "2. Build readiness"
KDIR="/lib/modules/$KVER/build"
[ -d "$KDIR" ] && ok "kernel headers present: $KDIR" || { bad "kernel headers MISSING at $KDIR - install them (Ubuntu: linux-headers-$KVER)"; VERDICT_BLOCKERS+=("headers"); }
if [ -r "$KDIR/.config" ] && grep -q 'CONFIG_CC_IS_CLANG=y' "$KDIR/.config" 2>/dev/null; then note "kernel built with: clang/LLVM"; for t in clang ld.lld llvm-ar; do command -v $t >/dev/null || warn "missing $t (needed to build against a clang kernel)"; done
else note "kernel built with: gcc"; command -v gcc >/dev/null && ok "gcc present" || { bad "gcc missing"; VERDICT_BLOCKERS+=("gcc"); }; fi
command -v make >/dev/null && ok "make present" || { bad "make missing"; VERDICT_BLOCKERS+=("make"); }
for g in mkinitcpio dracut update-initramfs; do command -v $g >/dev/null 2>&1 && { note "initramfs generator: $g"; break; }; done
if command -v update-grub >/dev/null 2>&1 || [ -f /boot/grub/grub.cfg ]; then note "bootloader: grub"; elif [ -d /boot/loader/entries ]; then note "bootloader: systemd-boot"; else warn "bootloader not identified (grub/systemd-boot) - rootflags step may need manual help"; fi
MODEXT="$(ls /lib/modules/$KVER/kernel/drivers/nvme/host/nvme.ko* 2>/dev/null | head -1)"; note "nvme module format: ${MODEXT##*nvme.ko}"

hdr "3. NVIDIA stack"
if command -v nvidia-smi >/dev/null 2>&1; then
	nvidia-smi --query-gpu=index,name,memory.total,pcie.link.gen.current,pcie.link.width.current,driver_version --format=csv,noheader 2>/dev/null | while IFS= read -r l; do note "GPU: $l"; done
	NG="$(nvidia-smi -L 2>/dev/null | wc -l)"; ok "$NG GPU(s) visible to the driver"
	[ -e /proc/driver/nvidia/version ] && grep -qi open /proc/driver/nvidia/version && ok "nvidia OPEN kernel module (required for the GPUDirect symbols)" || warn "could not confirm nvidia-OPEN module (GDS needs the open module's nvidia_p2p exports)"
else bad "nvidia-smi not found - install the NVIDIA driver (open kernel module) first"; VERDICT_BLOCKERS+=("no-driver"); fi
grep -qE 'nvidia_p2p_get_pages' /proc/kallsyms 2>/dev/null && ok "driver exports nvidia_p2p_get_pages (GPUDirect API present)" || warn "nvidia_p2p_get_pages not in kallsyms (driver not loaded, or does not export it)"
NVFS_SRC="$(ls -d /opt/cuda/usr/src/nvidia-fs-* /usr/src/nvidia-fs-* 2>/dev/null | head -1)"
[ -n "$NVFS_SRC" ] && ok "nvidia-fs source present: $NVFS_SRC" || warn "nvidia-fs source not found (needed: build it, or install nvidia-fs / the CUDA gds package)"
lsmod 2>/dev/null | grep -q nvidia_fs && note "nvidia_fs currently loaded" || note "nvidia_fs not currently loaded (fine; load it after install)"
GDSCHECK="$(ls /opt/cuda/gds/tools/gdscheck.py /usr/local/cuda*/gds/tools/gdscheck.py 2>/dev/null | head -1)"
[ -n "$GDSCHECK" ] && ok "cuFile/gdscheck present: $GDSCHECK" || warn "gdscheck not found (install CUDA + the GDS/cuFile package to actually use GDS)"

hdr "4. Is GDS already working (is the patch even needed)?"
NEEDED=1
if grep -qE 'nvme_v[12]_register_nvfs_dma_ops' /proc/kallsyms 2>/dev/null; then
	ok "the running nvme driver ALREADY exports the nvidia-fs hook - it is already GDS-patched (MOFED/DOCA, a distro, or a prior run). You likely do NOT need this patch."; NEEDED=0
fi
if [ -r /proc/driver/nvidia-fs/modules ] && grep -qiw nvme /proc/driver/nvidia-fs/modules 2>/dev/null; then
	ok "nvme is already registered with nvidia-fs - GDS via nvidia-fs is already active. Patch not needed."; NEEDED=0
fi
if [ -n "$GDSCHECK" ]; then
	NL="$(python3 "$GDSCHECK" -p 2>/dev/null | grep -iE '^[[:space:]]*NVMe[[:space:]]*:' | head -1 | tr -s ' ')"
	[ -n "$NL" ] && note "gdscheck says:$NL"
	case "$NL" in *Supported*) ok "gdscheck reports NVMe Supported - GDS may already work here without this patch (native path). Patch likely not needed."; NEEDED=0;; esac
fi
[ "$NEEDED" = "1" ] && note "=> No sign GDS already works; the nvme patch is likely NEEDED on this box."

hdr "5. PCIe topology (does the P2P actually have a path?)"
note "For GDS the NVMe must DMA into GPU BAR1. Best case: GPU + NVMe share a PCIe switch."
gpu_bdfs=$(lspci -Dn 2>/dev/null | awk '/ 0300: 10de|0302: 10de|0380: 10de/{print $1}')
nvme_bdfs=$(lspci -Dn 2>/dev/null | awk '/ 0108: /{print $1}')
upstream_chain(){ local d="$1" p; p="0000:${d#0000:}"; while :; do pp=$(basename "$(readlink -f /sys/bus/pci/devices/$p/../ 2>/dev/null)" 2>/dev/null); pp="${pp#pci}"; [ -z "$pp" ] || [ "$pp" = "0000:00" ] && { printf '%s' "$p"; break; }; printf '%s <- ' "$p"; p="$pp"; done; }
if [ -n "$gpu_bdfs" ] && [ -n "$nvme_bdfs" ]; then
	for g in $gpu_bdfs; do note "GPU  $g  path: $(upstream_chain "$g")"; done
	for n in $nvme_bdfs; do note "NVMe $n  path: $(upstream_chain "$n")"; done
	note "(If a GPU and an NVMe share an intermediate bridge/switch in their paths, P2P routes locally = good. If they only meet at the root complex (00:xx), P2P must cross it - works on some boards, not others.)"
else warn "could not enumerate GPU/NVMe via lspci (install pciutils; sudo gives fuller output)"; fi

hdr "6. Will the patch APPLY to your kernel? (fetches pci.c to /tmp, applies nothing to your system)"
if command -v curl >/dev/null 2>&1; then
	tag="v$BARE"; case "$BARE" in *.0) tag2="v$MAJ.$MIN";; *) tag2="";; esac
	tmp="$(mktemp)"; got=""
	for t in "$tag" ${tag2:+$tag2}; do
		if [ "$(curl -sL -o "$tmp" -w '%{http_code}' "https://raw.githubusercontent.com/gregkh/linux/$t/drivers/nvme/host/pci.c" 2>/dev/null)" = "200" ]; then got="$t"; break; fi
	done
	if [ -n "$got" ]; then
		note "fetched mainline nvme pci.c at tag $got"
		# load-bearing single-line anchors that must each appear exactly once
		miss=0
		check1(){ local c; c=$(grep -cF "$1" "$tmp" 2>/dev/null); [ "$c" = "1" ] || { warn "anchor absent/ambiguous ($c): ${2}"; miss=1; }; }
		check1 'static blk_status_t nvme_map_data(struct request *req)' "nvme_map_data"
		check1 'if (!blk_rq_dma_map_iter_next(req, dma_dev, iter))' "prp iter_next site"
		check1 '} while (blk_rq_dma_map_iter_next(req, nvmeq->dev->dev, iter));' "sgl iter_next site"
		check1 'static void nvme_free_descriptors(struct request *req)' "insertion point"
		check1 'struct nvme_sgl_desc *meta_descriptor;' "nvme_iod struct field insertion point"
		check1 'if (iod->flags & IOD_SINGLE_SEGMENT) {' "nvme_unmap_data nvfs-branch anchor"
		# Covers 5 of the patcher's 6 anchor sections (the 6th, nvme_unmap_iter,
		# is itself optional in lib/patch_nvme.py - skipped on kernels that
		# don't have it). Not exhaustive of every anchor inside each section -
		# the real patcher (lib/patch_nvme.py) is always the final authority.
		if [ "$miss" = "0" ]; then ok "your kernel's nvme layout matches the load-bearing anchors checked here - the patch is likely to APPLY cleanly (not exhaustive; the real patcher is authoritative)"
		else warn "one or more patch anchors do not match your kernel's pci.c - the installer will REFUSE (safely) on this kernel. Send us this pci.c ($got) and we can add support."; VERDICT_WARN+=("anchors"); fi
		note "(Note: this checked MAINLINE $got. If your distro patched its nvme driver, use install.sh --src-dir with your distro source; the real patcher is authoritative.)"
	else warn "could not fetch a mainline tag for kernel $BARE (tried $tag $tag2) - offline, or an unusual version. install.sh --src-dir can use your local source."; fi
	rm -f "$tmp"
else warn "curl not found - cannot test-fetch pci.c"; fi

hdr "VERDICT"
if [ "${#VERDICT_BLOCKERS[@]}" -gt 0 ]; then
	bad "BLOCKERS (fix these before install): ${VERDICT_BLOCKERS[*]}"
else
	ok "No hard blockers found."
fi
[ "${#VERDICT_WARN[@]}" -gt 0 ] && warn "Cautions: ${VERDICT_WARN[*]}"
[ "$NEEDED" = "0" ] && note "GDS may already work here - confirm before patching." || note "Patch appears needed; if the anchors matched above and the stack is present, install.sh should work (watch the first run)."
note "Send this whole output back so we can confirm before you run install.sh."
