# Reliable loading: the nvidia-fs concurrency gotcha

This patch makes GDS *available*. That is necessary but not always sufficient: a real weight
loader can still crash `nvidia-fs` even once the hook is in place. This note explains the failure
and a loader-side fix that works, so you do not chase it in the kernel.

---

## Symptom

With GDS engaged, a high-throughput loader (for example vLLM's `fastsafetensors` path, or any
loader that GDS-reads straight into many destination tensors) does one of:

- crashes the driver with a null-pointer dereference inside `nvfs_get_p2p_dma_mapping` /
  `nvfs_mgroup_*`, often taking the box down with it, or
- hangs at 0% forever, sometimes with `nvfs_mgroup ... IO is in CALLBACK_END state` /
  `Invalid vaddr` in `dmesg`.

Notably the PCIe AER layer stays quiet through this - it is not a link/signal problem.

---

## Cause

The crash is a concurrency race in `nvidia-fs`'s mapping/mgroup bookkeeping, not in this NVMe
patch. Loaders that register the **final destination tensors** as GDS targets create many GPU
BAR1 mappings and drive many concurrent NVMe reads against them. Each read is a separate driver
IO keyed off the buffer, and the bookkeeping for one IO's teardown can still be in flight when
the next IO reuses the same key - a use-after-teardown that dereferences stale state on the NVMe
submit path (`nvme_prep_rq -> nvfs_blk_rq_dma_map_iter_start -> nvfs_get_p2p_dma_mapping`).

Two consequences worth knowing:

- **Thread/queue knobs do not help.** The trigger is the *buffer-registration pattern* and the
  concurrency of the mappings, not the number of copy threads. Turning `fastsafetensors`
  threads or queue size down does not change what gets registered, so it still races.
- **It is easier to hit on slow/marginal P2P links.** A slower link widens the timing window,
  so an unlocked CMP 170HX at low PCIe width reproduces it readily. Fast, vendor-validated
  datacenter GPUs mostly do not - the window is narrow and the path is tested there.

---

## Fix: bounded staging (loader side)

The reliable pattern avoids the race entirely instead of fixing the driver:

1. Register a small **pool** of staging buffers in VRAM once (a handful of stable GDS mappings,
   never churned).
2. Read each tensor in aligned chunks, **rotating** to the next buffer in the pool for each read,
   then device-to-device copy the bytes into the destination tensor.
3. Because reads rotate across N buffers, a buffer's mapping is never reused until N reads later
   - long after its prior IO has torn down - so the use-after-teardown never happens.

One stable set of mappings, no churn, no lifecycle race. Loads come out byte-correct. Peak extra
VRAM is just the pool plus one tensor, so it also handles models larger than host RAM.

A reference implementation as a drop-in vLLM loader (`--load-format gds_bounded`, registered as a
plugin so vLLM and fastsafetensors stay stock) is here:
**https://github.com/cachenetics/vllm-gds-bounded**

---

## Same-boot caveat and reset

The pool fixes reuse *within* a load. Across loads in the same boot, `nvidia-fs` can still retain
mapping state, so the *first* GDS load after a boot is the most reliable and a later one can wedge.
Two ways to keep restarts clean:

- **Reset the module between loads:** `rmmod nvidia_fs && modprobe/insmod nvidia_fs`. This needs the
  loader to have released cuFile cleanly (module refcount back to 0); a hard-killed loader leaks
  refs and blocks the reset. Doing the reset *right after* a load completes (the serve does not use
  `nvidia-fs` once weights are in VRAM) leaves the module fresh for the next load.
- **Reboot** for a guaranteed clean slate. Note some boards do not honor a software reboot and need
  a physical power-cycle.

If you only load once per boot (the common serving case), none of this bites.
