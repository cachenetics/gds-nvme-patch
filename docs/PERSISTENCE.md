# Kernel-update persistence

Without this, a kernel update overwrites `nvme.ko` with the distro's stock one and GDS silently
stops working - nothing tells you, `nvidia-fs` just no longer sees the `nvme` registration on the
next boot into the new kernel.

`install.sh` (default `--persist`, disable with `--no-persist`) fixes this by:

1. Copying the tool - `lib/patch_nvme.py`, `lib/detect.sh`, `lib/build.sh`, `lib/rebuild.sh`, and
   the `gds-nvme-rebuild` CLI wrapper - to a stable location, `/usr/lib/gds-nvme-patch/`. Hooks
   always call *that* copy, never a git checkout (which can move, be deleted, or be mid-edit).
2. Installing one distro-appropriate hook that fires after a kernel package installs/upgrades and
   reruns the fetch/patch/build/verify/install pipeline for the new kernel, via
   `gds-nvme-rebuild <kernel-version>` -> `lib/rebuild.sh`'s `gds_rebuild_kernel`.

See the top-level README's "What the installer does" section for where this fits in the overall
install flow, and `--help` on `install.sh`/`uninstall.sh` for the exact flags.

## Why not DKMS

DKMS's model is: vendor a fixed source tree once under `/usr/src/<pkg>-<ver>/`, then just `make` it
against whatever kernel headers are current. This project instead fetches the *exact* upstream
`drivers/nvme/host/{pci.c,core.c,nvme.h,fabrics.h,trace.h}` for the *specific* kernel version being
targeted (a moving target - every kernel micro-version bump is a different upstream tag, and some
distros patch their nvme driver so even that isn't enough - see `install.sh --src-dir`), then
patches it with a script that **refuses on any anchor mismatch** rather than best-effort applying.
DKMS has no hook for "go fetch version-matched source first, and abort cleanly rather than build if
it doesn't match" - `PRE_BUILD` is the closest fit, but wiring dkms to also propagate a
per-kernel-version target (rather than "whatever headers happen to be current") and to stop, not
partially install, on a refusal fights the tool rather than using it as intended. A distro
kernel-update hook that calls back into this repo's own version-aware pipeline directly is a much
better fit, and is what this repo does instead.

## The fail-safe contract (why an unattended rebuild is safe)

`lib/rebuild.sh`'s `gds_rebuild_kernel <KVER>` runs unattended inside a package manager transaction
(pacman/apt/dnf). It is built so that **it can never make things worse than not running at all**:

- It **never exits nonzero** in a way that could fail/abort the kernel package transaction - every
  step is `if ! step; then log-and-leave-stock; return 0; fi`, and the outer `gds_rebuild_kernel`
  and the `gds-nvme-rebuild` CLI wrapper both guarantee a `return 0` / `exit 0` regardless of what
  happened inside.
- On **any** doubt - no headers yet, already patched, the patcher refuses (unsupported kernel
  shape), the build fails, vermagic doesn't match, anything - it **leaves that kernel's stock
  `nvme.ko` untouched** and logs why to `/var/log/gds-nvme-patch/rebuild-<KVER>.log`, plus a
  one-line summary to stdout (visible in the pacman/apt/dnf transaction output).
- It only installs the patched module - after backing up the stock one to
  `/var/lib/gds-nvme-patch/backups/<KVER>/`, same as `install.sh` - once the build **and** a
  vermagic check **and** the `nvme_v2_register_nvfs_dma_ops` symbol check have all passed for that
  exact kernel version.
- It never touches the bootloader cmdline. `rootflags=data=ordered` is set once, at first install,
  in the shared `/etc/default/grub` (regenerated into `grub.cfg`, which covers every kernel) or the
  systemd-boot entry `install.sh` edited - it does not need to be redone per kernel update.

## What's tested vs template

- **Tested** on a CachyOS/Arch box (kernel headers present, patch applies): `install.sh --dry-run`
  with the persist plan reported, the pacman hook + `/usr/lib/gds-nvme-patch/` install, a real
  `gds-nvme-rebuild <running-kernel-version>` run (re-fetch, patch, build, vermagic-check, install,
  initramfs regen, `nvme_v2_register_nvfs_dma_ops` present afterward), and the fail-safe path on a
  second installed kernel the patch does not support (6.18-shape LTS: left stock, refusal logged
  clearly, exit 0).
- **Template quality, not exercised on a real box**: the Fedora/RHEL `kernel-install` plugin
  (`hooks/fedora/95-gds-nvme-patch.install`) - written to the documented plugin contract
  (`$1`=command, `$2`=kernel version) but not run against a real `kernel-install` invocation.
- **Coded, not run end-to-end on a real kernel upgrade**: the Debian/Ubuntu `postinst.d` hook
  (`hooks/debian/zz-gds-nvme-patch`) - the contract (`$1`=kernel version) matches
  `kernel-package`/`linux-base`'s documented behavior and `install.sh`'s own untested-on-real-box
  Debian/Ubuntu install path (see the top-level README's Status section), but nobody has run an
  actual `apt upgrade` of a kernel package against it yet.

## Manual fallback

If persistence isn't installed (`--no-persist`, or an unsupported package manager), the old manual
path still works and is always safe:

```sh
sudo ./install.sh     # re-detect, re-fetch, re-patch, re-build, re-install for the NEW kernel
```

`install.sh` is idempotent and kernel-version-scoped (state lives at
`/var/lib/gds-nvme-patch/backups/<kernel-version>/`), so rerunning it after every kernel update is
always safe, hook or no hook.
