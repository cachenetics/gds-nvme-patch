# gds-nvme-patch

Makes NVIDIA **GPUDirect Storage (GDS)** work on modern Linux kernels (6.18+), which NVIDIA's own
driver support does not cover yet.

Small patch to the kernel's NVMe driver + an installer that maintains it across kernel updates.

---

## What is GDS?

Reading a file into GPU memory normally detours through the CPU and system RAM:

```
NVMe  ->  system RAM (CPU copies)  ->  GPU VRAM
```

GDS sends it straight there:

```
NVMe  ------ direct DMA ------>  GPU VRAM
```

Result: less host RAM, less CPU, more bandwidth. Used for loading model weights and datasets into
VRAM (AI/ML, RAPIDS/kvikio, DALI) - especially on many-GPU, low-host-RAM rigs.

---

## Why a kernel patch?

For the NVMe to DMA straight into GPU memory, two drivers have to cooperate: the kernel's **NVMe
driver** and NVIDIA's **`nvidia-fs`** module. They connect through one specific hook - the NVMe
driver has to export a function (`nvme_v2_register_nvfs_dma_ops`) that `nvidia-fs` looks for when it
loads. If that hook is present, `nvidia-fs` plugs into the NVMe I/O path and GDS works. If it's
missing, cuFile just reports `NVMe : Unsupported` and there's nothing you can configure to fix it.

Here's the problem:

1. **That hook is not in the stock kernel.** It's an out-of-tree patch NVIDIA maintains.
2. **NVIDIA ships it only inside MOFED / DOCA-OFED**, not in the mainline kernel.
3. **And only for the old NVMe code.** Their patch is written against the pre-6.18 DMA-mapping API,
   so it only applies to kernels **<= 6.17**.
4. **Kernel 6.18 rewrote the NVMe DMA path** to a new iterator API (`blk_rq_dma_map_iter`).
   NVIDIA's patch doesn't fit the new code, and they haven't published an updated one.

So on any current (6.18+) kernel there is simply no way to get that hook in - GDS is stuck at
`Unsupported`, no matter what driver or CUDA version you install.

**This repo is that missing hook, rewritten for the 6.18+ NVMe API.** It adds only the registration
code to the NVMe driver - nothing GPU-specific (a CMP 170HX was just the test card).

---

## Do you even need it?

- **Software uses cuFile/GDS + kernel 6.18+ + `gdscheck` says `Unsupported`** -> yes.
- **`gdscheck` already says `Supported`** (Grace-Hopper, MOFED kernel) -> no.
- **You just want low-RAM loading and write your own loader** -> maybe not. `O_DIRECT` + a small
  pinned buffer gets most of the benefit with no kernel patch. Details in the README's history / ask.

Run `probe.sh` (below) and it tells you which case you're in.

---

## Quick start

```sh
sudo bash probe.sh | tee gds-probe.txt   # read-only: checks readiness, touches nothing
sudo ./install.sh                        # build + install + kernel-update hook
# reboot if root is on NVMe, then:
gdscheck.py -p                           # NVMe should read 'Supported' / 'nvfs'
```

Uninstall: `sudo ./uninstall.sh`

---

## Good to know

- **Kernels:** 7.0 and 7.1 apply. 6.17/6.18 and older are not supported yet (the patcher refuses
  safely - it never mispatches).
- **Safe by design:** identical to the stock driver for all normal disk I/O; only GPU-buffer
  transfers take the GDS path. Backs up before changing anything, keeps a rescue kernel, and refuses
  on any kernel it doesn't recognize.
- **Tested:** end-to-end on CachyOS 7.1.5. Kernel 7.0 (Ubuntu 26.04) verified at the patch level;
  a full Debian/Ubuntu install is coded but not yet run on real hardware.
- **Persistence:** a kernel update would revert to the stock driver, so the installer adds a hook
  (pacman / apt / dnf) that re-patches new kernels, failing safe on ones it can't. `--no-persist` to
  skip.
- **Will the P2P physically work?** The NVMe still has to reach GPU memory over PCIe - best when they
  share a switch. `probe.sh` shows your topology.

More detail: `docs/DEPLOYMENT-MODES.md` (reboot vs. live), `docs/PERSISTENCE.md`.

---

## Requirements

Kernel 6.18+, x86_64, kernel headers, `nvidia-open` + `nvidia-fs`, CUDA/cuFile.

## License

GPL-2.0 (it derives from the GPL-2.0 kernel NVMe driver).
