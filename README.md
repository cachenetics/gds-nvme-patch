# gds-nvme-patch

Enable **NVIDIA GPUDirect Storage (GDS)** on Linux kernels that are *newer* than the ones
NVIDIA's MOFED / DOCA nvme patch supports.

GDS lets an NVMe drive DMA data directly to/from GPU VRAM, bypassing the CPU bounce buffer. On
the `nvidia-fs` path this requires the kernel's **nvme host driver** to register with `nvidia-fs`
(the symbol `nvme_v2_register_nvfs_dma_ops`). NVIDIA ships that nvme patch only inside MOFED /
DOCA-OFED, and it targets the **old** block DMA-mapping API (`blk_rq_map_sg` / `dma_map_sg`,
kernels <= 6.17). Kernel **6.18+** switched the nvme driver to the new iterator API
(`blk_rq_dma_map_iter` / `dma_iova_state`), and NVIDIA has not published an nvme patch for it.

This repo provides that missing patch (written against the iterator API) plus a distro-aware
installer, so GDS works on current kernels.

The patch is **GPU-agnostic** - it patches the *nvme driver*, not the GPU driver. It was developed
and verified enabling GDS on an NVIDIA CMP 170HX, but nothing here is 170HX-specific. (Unlocking a
170HX's memory is a *separate* project.)

## Status - read this before running

- **Root is (usually) on your NVMe.** This patch replaces the nvme driver that mounts root. A bad
  build = an unbootable kernel. The installer keeps your other installed kernel untouched as a
  rescue, backs up the stock module + initramfs, and the patch is **byte-identical to stock until
  nvidia-fs actually registers** (so boot/normal I/O is unaffected). But you accept the risk.
- **What is actually tested:** on CachyOS / kernel 7.1.5 / x86_64 / nvidia-open 610.43.03 +
  nvidia-fs 2.29 (root on the NVMe), the **full `install.sh` and `uninstall.sh` were run
  end-to-end** - install produced a working GDS transfer with data-integrity verify passing, and
  uninstall cleanly restored stock (GDS gone). The refuse/edge paths (non-root, bad kernel,
  anchor-mismatch) are tested. The **patch application on kernel 7.0** (Ubuntu 26.04) is validated
  against mainline v7.0 source, but a **full install on a real Debian/Ubuntu box has not been
  run** - the `update-initramfs`/`dracut`/`gcc`/systemd-boot paths are coded + reviewed but
  unexercised. **Mode B** (live reload) and **Mode C** (livepatch) are unverified (see
  `docs/DEPLOYMENT-MODES.md`). Treat anything outside the first sentence as designed-but-untested.
- **The patcher refuses (does not apply) if it cannot match your kernel's nvme source exactly.**
  That is deliberate: silently mispatching the root-disk driver is the one outcome worse than
  "unsupported". If it refuses on your kernel, the anchors need updating for that version - open
  an issue with your `drivers/nvme/host/pci.c`.

## Kernel support (which versions the patch applies to)

The patch targets the `blk_rq_dma_map_iter` nvme path (kernel 6.18+). Because it edits `pci.c` by
matching code anchors, the exact code shape has to match. Current state:

| Kernel   | Result            | Notes                                                        |
|----------|-------------------|--------------------------------------------------------------|
| 7.0      | **applies**       | Ubuntu 26.04's kernel. `nvme_unmap_iter` guard auto-skipped. |
| 7.1.x    | **applies**       | Verified end-to-end (real GDS transfer).                     |
| 6.17/6.18| refuses (safely)  | Iterator API present but different code shape; anchors TODO. |
| <= 6.17* | refuses (legacy)  | Pre-iterator nvme API; use NVIDIA's MOFED/DOCA patch instead.|

The patcher **refuses rather than mispatching** whenever the anchors do not match - so an
unsupported kernel fails safely, it never corrupts the root-disk driver. If it refuses on a kernel
you need, the anchors need extending for that version (open an issue with your `pci.c`).

## Requirements
- x86_64, an NVMe drive, kernel headers for the running kernel installed.
- `nvidia-open` (or nvidia) driver + `nvidia-fs` built/loadable, CUDA + cuFile (for `gdscheck`/`gdsio`).
- A supported PCIe topology for the P2P itself (see "Will the DMA actually work?" below).

## Usage

```sh
sudo ./install.sh            # detect, patch, build, install into initramfs, set data=ordered
sudo ./install.sh --dry-run  # detect + patch + build only; do not touch /boot or /lib/modules
sudo ./uninstall.sh          # restore the stock nvme module + initramfs
```

After install + reboot, load nvidia-fs and check:

```sh
/opt/cuda/gds/tools/gdscheck.py -p          # NVMe should read 'Supported' / 'nvfs'
cat /proc/driver/nvidia-fs/modules          # should list 'nvme'
gdsio -D <dir on the NVMe> -d 0 -w 1 -s 32M -i 1M -x 0 -I 1 -V   # write+verify a real GDS transfer
```

## What the installer does (and how it stays distro-agnostic)

1. **Detects** kernel version + nvme API era, the kernel build toolchain (gcc vs clang/LLVM, read
   from the kernel's own build flags), module compression (`.ko` / `.ko.zst` / `.ko.xz`), the
   initramfs generator (`mkinitcpio` / `dracut` / `update-initramfs`), and the bootloader
   (`grub` / `systemd-boot`).
2. **Acquires** the matching nvme host source, in this order: an explicit `--src-dir=PATH`, then an
   auto-detected local kernel source tree, then the mainline stable tree (with version-tag
   normalization, e.g. a distro `7.0.0` maps to the tag `v7.0`). If your distro patches its nvme
   driver so the mainline source does not match, the patcher refuses (safely) - point it at your
   distro's own source: `apt-get source linux` (Debian/Ubuntu) or the kernel-devel tree (Fedora),
   then `--src-dir=<that path>`.
3. **Patches** `pci.c` (refuses on any anchor mismatch) and **builds** `nvme.ko` out-of-tree
   against your installed headers, with the detected toolchain. (MODVERSIONS on or off both work;
   off loads by name, on matches CRCs from your headers' Module.symvers.)
4. **Installs** the module (backing up the stock one), regenerates the initramfs for the *current*
   kernel only, and leaves any other installed kernel as a rescue.
5. **Sets `rootflags=data=ordered`** on the kernel cmdline (cuFile refuses ext4 unless it can
   verify `data=ordered` in the mount table) via the detected bootloader.
6. Optionally installs a **DKMS**-style hook so the patch survives kernel updates (see `dkms/`).

## Will the DMA actually work? (topology)

Registering nvme with nvidia-fs is necessary but not sufficient - the NVMe still has to be able to
P2P-DMA into GPU BAR1. That depends on your PCIe topology:

- **Best:** NVMe and GPU under a common PCIe switch (server/backplane, or a PCIe switch card).
- **Consumer boards:** we verified it works even across *separate* AMD CPU root ports (GPU on a
  CPU root port, NVMe behind the chipset switch) at ~Gen2/Gen3 x4 speeds - nvidia's driver refuses
  this by *policy* (chipset-unsupported + coherent-only gates on the native path), but the legacy
  nvidia-fs path this patch enables bypasses those gates and the hardware carried it. Your mileage
  will vary by board.
- If the hardware genuinely cannot route the P2P, transfers fail/time out (they will not silently
  corrupt - GPU addresses are never handed to a normal dma_unmap).

## A note on payoff

GDS's headline benefit is bandwidth (7-14 GB/s per Gen4/5 NVMe). If your card's PCIe link is
narrow (e.g. a 170HX at Gen2 x4, ~1.7 GB/s), **GDS gives no bandwidth win over plain O_DIRECT** -
its only value there is not consuming host RAM / CPU for staging, which matters for many-GPU
low-host-RAM rigs. Size your expectations to your link.

## License

GPL-2.0. The patch adds code to and is derived from the Linux kernel's `drivers/nvme/host/pci.c`
(GPL-2.0-only); the tooling is distributed under the same terms for simplicity.

The exported registration symbol is `EXPORT_SYMBOL_GPL` on purpose - recent kernels refuse
`symbol_get()` on non-GPL symbols, so a plain `EXPORT_SYMBOL` silently fails to register.
