# dkms/ - kernel-update survival, template status

`dkms.conf` in this directory is a **documented template**, not a verified
DKMS package. It exists so the intent and the wiring points are explicit
rather than the repo silently having no story for "a kernel update just
overwrote the patched module."

## What is tested vs what is a template

- **Tested** (via `install.sh` directly, see the top-level `README.md`
  "Status" section): fetch the matching nvme source for a given kernel
  version, apply `lib/patch_nvme.py`, build `nvme.ko`, install it, regenerate
  the initramfs, set the `rootflags=data=ordered` cmdline. All of that logic
  lives in `lib/build.sh` / `lib/detect.sh` and is exercised by `install.sh`.
- **Template only, NOT tested**: wiring that same logic into DKMS's
  `PRE_BUILD` / `MAKE` / `POST_INSTALL` hooks so it reruns automatically on
  every kernel package upgrade. `dkms.conf`'s `PRE_BUILD`/`POST_INSTALL`
  lines are commented out and point at scripts (`scripts/dkms-prebuild.sh`,
  `scripts/dkms-postinstall.sh`) that do not exist yet - see the comments at
  the top of `dkms.conf` for exactly what they would need to do.

## Why DKMS doesn't drop in cleanly here

DKMS's normal model is: vendor the source once under
`/usr/src/<pkg>-<ver>/`, then just `make` it against whatever kernel headers
are current. This project instead fetches the **exact upstream source for
the exact running kernel version** at build time (a moving target - every
kernel micro-version bump means a different upstream tag), then patches it
with a script that **refuses on any anchor mismatch** rather than best-effort
applying. That refuse-on-mismatch behavior is deliberate and must never be
bypassed by any automation, including DKMS hooks - a kernel update whose
`pci.c` shape has drifted should fail loudly, not silently mis-patch the
root-disk driver.

## Until the hooks are written: the safe path today

Rerun the tested path manually after a kernel update:

```sh
sudo ./uninstall.sh   # restore stock module + initramfs for the OLD kernel, if you want a clean state
# ... update / reboot into the new kernel ...
sudo ./install.sh     # re-detect, re-fetch, re-patch, re-build, re-install for the NEW kernel
```

`install.sh` and `uninstall.sh` are both idempotent and kernel-version-scoped
(state lives at `/var/lib/gds-nvme-patch/backups/<kernel-version>/`), so this
is safe to do on every kernel update without any DKMS automation.

## Wiring it up for real (if you pick this up)

1. Install this whole repo under `/usr/src/gds-nvme-patch-1/` (the version
   suffix must match `PACKAGE_VERSION` in `dkms.conf`).
2. `dkms add -m gds-nvme-patch -v 1`.
3. Write `scripts/dkms-prebuild.sh`: source `lib/build.sh` and call
   `fetch_nvme_source "$kernelver" "$dkms_tree/gds-nvme-patch/1/build"` then
   `apply_nvme_patch` against that directory. `$kernelver` is provided by
   dkms inside `PRE_BUILD`.
4. Write `scripts/dkms-postinstall.sh`: source `lib/build.sh` /
   `lib/detect.sh`, redetect the initramfs generator + bootloader (they don't
   change between kernel updates, but re-detecting is cheap and keeps this
   script correct if the host's config ever changes), call `regen_initramfs`
   and, if root is ext4, `set_cmdline_grub` / `set_cmdline_systemd_boot`
   (both are idempotent - safe to call on every kernel update).
5. Uncomment the `PRE_BUILD` / `POST_INSTALL` lines in `dkms.conf`.
6. Test on a throwaway kernel update before trusting it on anything with
   root on the patched drive - the anchor-mismatch refusal in
   `lib/patch_nvme.py` needs to actually stop a `dkms autoinstall` run
   cleanly (nonzero exit, no half-applied module installed) and this has not
   been verified.
