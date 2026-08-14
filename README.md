# gds-nvme-patch

**Make NVIDIA GPUDirect Storage (GDS) work on modern Linux kernels (6.18+)**, where NVIDIA's own
driver support does not reach yet. It is a small, self-contained patch to the kernel's NVMe driver,
plus an installer that builds and maintains it across kernel updates.

---

## What is GDS, and why would you want it?

Normally, reading a file from an NVMe drive into GPU memory takes a detour through the CPU:

```
   NVMe  ->  system RAM (CPU copies it)  ->  GPU VRAM
```

**GPUDirect Storage (GDS)** cuts out the middle step. The NVMe drive DMAs the data *straight into
GPU memory*:

```
   NVMe  ------ direct DMA ------>  GPU VRAM
```

Skipping the CPU/RAM hop means:

- **Less host RAM used** - you are not staging gigabytes through system memory. This is the big one
  for rigs with many GPUs and limited host RAM.
- **Less CPU** - no copy loop tying up cores.
- **More bandwidth** on fast drives (up to the PCIe link limit).

You use it (usually via NVIDIA's **cuFile** API) for things like loading model weights and datasets
into VRAM: AI/ML training and inference, RAPIDS / kvikio, NVIDIA DALI, and any multi-GPU box where
feeding the GPUs from storage without exhausting host RAM matters.

---

## Why is a kernel patch needed at all?

To do GDS through nvidia-fs, the kernel's **NVMe driver has to register itself with NVIDIA's
`nvidia-fs` module** (it exports a function called `nvme_v2_register_nvfs_dma_ops`). Stock kernels
do not have that code.

NVIDIA does provide it - but only:

1. bundled inside **MOFED / DOCA-OFED**, and
2. written for the **old** kernel block-DMA API (`blk_rq_map_sg`), which means **kernels up to
   6.17 only.**

**Kernel 6.18 rewrote the NVMe DMA path** to a new iterator API (`blk_rq_dma_map_iter`). NVIDIA has
not published an NVMe patch for it. So on any current kernel, `nvidia-fs` cannot hook the NVMe
driver, `gdscheck` reports `NVMe : Unsupported`, and cuFile silently falls back to the slow
CPU-copy path (or refuses).

**This repo is that missing piece:** the NVMe registration hooks, written against the new
6.18+ iterator API. It patches only the NVMe driver - it is GPU-agnostic and has nothing to do with
any specific card. (It was developed and verified enabling GDS on an NVIDIA CMP 170HX, but that is
just the test hardware.)

---

## Do you actually need it?

Be honest with yourself here - patching the root-disk driver is not free, so skip it if you can:

- **If your software calls cuFile / GDS** (RAPIDS, DALI, a framework's GDS data loader, your own
  cuFile code) and you are on a 6.18+ kernel where GDS reports `Unsupported` -> **yes, you need
  this** (or an older, MOFED-supported kernel).
- **If GDS already works on your box** (`gdscheck` shows `Supported`, e.g. a Grace-Hopper / coherent
  platform, or a MOFED-patched kernel) -> **you do not need this.** The `probe.sh` script below
  tells you.
- **If you just want "load data into VRAM without eating host RAM" and control the load path
  yourself** -> you may not need GDS *or* this patch at all. Plain `O_DIRECT` reads into a small
  pinned buffer + `cudaMemcpyAsync` bypass the page cache with a tiny, bounded host footprint, work
  on any kernel, and - on a modest PCIe link - hit the same bandwidth as true GDS anyway. No kernel
  patch, no maintenance.

---

## Quick start

**1. Probe first (read-only, touches nothing).** It checks your box is ready and that the patch
will apply to your kernel:

```sh
sudo bash probe.sh | tee gds-probe.txt
```

**2. Install** (builds the patched module, stages it, and by default installs a kernel-update hook
so it survives future kernel updates):

```sh
sudo ./install.sh
```

If your root filesystem is on an NVMe drive, the new driver takes effect on the **next reboot** (the
running driver cannot be hot-swapped). The installer keeps your other installed kernel as a rescue
and backs everything up first.

**3. After reboot, confirm GDS is live:**

```sh
gdscheck.py -p                       # NVMe should now read 'Supported' / 'nvfs'
cat /proc/driver/nvidia-fs/modules   # should list 'nvme'
# a real transfer, write + verify:
gdsio -D <dir on the NVMe> -d 0 -w 1 -s 32M -i 1M -x 0 -I 1 -V
```

**Uninstall** (restores the stock driver + removes the hooks):

```sh
sudo ./uninstall.sh
```

---

## Requirements

- **Kernel 6.18+**, x86_64, kernel headers for your running kernel installed.
- `nvidia-open` (or nvidia) driver + `nvidia-fs`, and CUDA + cuFile (for `gdscheck` / `gdsio`).
- A PCIe topology that can actually carry the P2P (see "Will the P2P actually work?" below).

---

## Kernel support

The patch edits `drivers/nvme/host/pci.c` by matching code anchors, so the exact kernel shape has
to match. It **refuses rather than mispatching** if it does not - so an unsupported kernel fails
safely, it never corrupts the driver.

| Kernel     | Result           | Notes                                                    |
|------------|------------------|--------------------------------------------------------|
| 7.0        | applies          | Ubuntu 26.04's kernel. Verified at the patch level.     |
| 7.1.x      | applies          | Verified end-to-end (real GDS transfer).                |
| 6.17, 6.18 | refuses (safely) | Iterator API but a different code shape; anchors TODO.  |
| <= 6.17    | refuses (legacy) | Pre-iterator API; use NVIDIA's MOFED/DOCA patch instead.|

If it refuses on a kernel you need, the anchors just need extending for that version - open an issue
with your `drivers/nvme/host/pci.c`.

---

## Status - what is actually tested

- **Fully tested, end to end:** CachyOS, kernel 7.1.5, x86_64, nvidia-open 610.43.03 + nvidia-fs
  2.29, root on NVMe. `install.sh` + `uninstall.sh` run clean, GDS transfers work with data-verify
  passing, the kernel-update hook re-patches supported kernels and safely leaves unsupported ones
  stock.
- **Patch-applies verified** on kernel 7.0 (Ubuntu 26.04) against mainline source.
- **Designed and reviewed but not yet run on real hardware:** a full Debian/Ubuntu or Fedora
  install (the `gcc` build, `update-initramfs` / `dracut`, systemd-boot), Mode B (live reload), and
  the livepatch mode. Treat these as unproven until someone runs them.

This is a solid v0.x. It has real safety nets (below), but you should read this section and run
`probe.sh` before trusting it on a box you care about.

---

## How it works, and why it is safe on your root disk

The patch is a **conditional divert, not a takeover.** For every NVMe I/O request, it asks
nvidia-fs: "is this a GPU buffer?" If yes, the transfer goes the GDS path; if no - which is *all*
your normal filesystem and root-disk I/O - it falls through to the **unchanged, stock code path,
byte for byte.** And when `nvidia-fs` is not loaded at all, the patched driver is identical to
stock.

Safety nets the installer gives you:

- **Backs up** the stock module, initramfs, and bootloader config before changing anything.
- **Keeps your other installed kernel untouched** as a rescue, and refuses to proceed on a
  root-on-NVMe box that has no rescue kernel (unless you `--force`).
- **Refuses to mispatch** an unrecognized kernel (fails safe, never silently wrong).
- The **kernel-update hook fails safe**: if a future kernel's shape is not supported, it leaves that
  kernel's stock driver in place, logs why, and never blocks the update or breaks boot.

---

## Will the P2P actually work? (topology)

Registering NVMe with nvidia-fs is necessary but not sufficient - the NVMe still has to be able to
DMA into GPU BAR1, and that depends on your PCIe layout:

- **Best:** NVMe and GPU under a common PCIe switch (a server/backplane, or a PCIe switch card) -
  the P2P routes locally.
- **Consumer boards:** it can still work even across separate CPU root ports (verified), but it is
  board-dependent and NVIDIA does not officially support it.
- If the hardware genuinely cannot route the P2P, transfers fail or time out - they will **not**
  silently corrupt (GPU addresses are never handed to a normal unmap).

`probe.sh` prints your GPUs' and NVMe's PCIe paths so you can see which case you are in.

---

## Kernel-update persistence

A kernel update replaces the NVMe module with the distro's stock one, so without help GDS breaks the
next time you boot a new kernel. `install.sh` installs a kernel-update hook by default (pacman on
Arch/CachyOS, `/etc/kernel/postinst.d` on Debian/Ubuntu, `kernel-install` on Fedora) that rebuilds
the patch for each new kernel - and **fails safe** if the patch cannot apply to it. Disable with
`--no-persist`. See `docs/PERSISTENCE.md`.

---

## Deployment modes (reboot vs. live)

- **Mode A (reboot):** required when root is on an NVMe. One reboot; keep a rescue kernel.
- **Mode B (live reload, no reboot):** when root is *not* on an NVMe (OS on a separate disk, NVMe
  for data) - the module can be swapped live.
- **Mode C (livepatch):** rebootless even with root on NVMe, but only on kernels with livepatch
  enabled and the target functions un-inlined. Not implemented yet.

See `docs/DEPLOYMENT-MODES.md`.

---

## License

GPL-2.0. The patch adds to and derives from the Linux kernel's `drivers/nvme/host/pci.c`
(GPL-2.0-only), so the whole repo is distributed under the same terms.
