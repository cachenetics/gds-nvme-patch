# Deployment modes: reboot vs. live

The patch adds GDS hooks to the kernel's **nvme** driver. How you apply it without breaking your
system depends on one thing: **is the nvme module in use by your root filesystem?**

## Mode A - rebuild + reboot (always works)

Rebuild `nvme.ko` with the patch, install it, regenerate the initramfs, reboot.

- Required when **root is on an NVMe** - the `nvme` module is in use and cannot be hot-swapped, so
  the new module only takes effect on the next boot (from the initramfs).
- Safety: the patch is byte-identical to stock until `nvidia-fs` actually registers, so a patched
  kernel boots and runs normal I/O exactly like stock. Keep a second (stock-nvme) kernel installed
  as a rescue; the installer refuses Mode A without one unless `--force`.
- **Status: verified.** This is how the patch was developed and confirmed working.

## Mode B - live module reload (no reboot)

`rmmod` the nvme stack and `insmod` the patched module, live.

- Works **only when root is NOT on an NVMe** (e.g. the OS is on a SATA/USB disk and NVMe is
  data-only). Then nothing pins the module and it can be swapped without a reboot.
- This is the sensible layout for a dedicated GDS rig anyway: put the OS on a cheap boot disk,
  keep the NVMe(s) for data. The installer auto-detects root-on-nvme and picks Mode B when it can.
- **Status: implemented, unverified** - our test box had root on its only NVMe, so we could not
  exercise the live reload. The mechanism is standard (`rmmod`/`modprobe`); treat as untested until
  someone runs it on a root-off-nvme box.

## Mode C - livepatch (no reboot, even with root on NVMe)

Use the kernel livepatch framework (or ftrace direct-calls) to replace the live nvme functions
without touching the in-use module.

- **Two hard prerequisites, both kernel-build properties:**
  1. `CONFIG_LIVEPATCH=y` (most distro kernels ship it for rebootless security fixes; some custom
     kernels compile it out).
  2. The target functions (`nvme_map_data`, `nvme_unmap_data`, `nvme_pci_setup_data_sgl`, ...) must
     exist as real symbols in `kallsyms` - i.e. **not inlined away**. Aggressively-optimized kernels
     (`-O3` / LTO) inline them, leaving nothing to patch. Check with:
     `grep -c ' nvme_map_data$' /proc/kallsyms` (0 = inlined = Mode C impossible on that kernel).
- **Additional design constraint:** livepatch can replace *functions* but cannot *grow a struct*.
  The rebuild patch adds per-request fields to `struct nvme_iod`; a livepatch version must instead
  keep per-request state in an external `request -> state` table (with a lock), looked up on the
  I/O path. More code, and a small hot-path cost.
- **Status: not implemented.** On the kernel this was developed against, `CONFIG_LIVEPATCH` was off
  AND the functions were inlined, so Mode C was impossible there. It is plausible on stock distro
  kernels (livepatch enabled, lighter inlining) but has not been built or tested. Contributions
  welcome.

## Recommendation

- Building a dedicated GDS box? Put the OS on a small SATA/USB disk -> **Mode B**, no reboots ever.
- Root already on the NVMe -> **Mode A**, one reboot, keep a rescue kernel.
- Need rebootless on a root-on-nvme box -> **Mode C**, only if your kernel has livepatch on and the
  nvme functions un-inlined; expect real work.
