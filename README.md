# Ender 3 V3 Plus mainline Klipper update channel

This repository is the guarded host-update channel for one commissioned
Creality Ender 3 V3 Plus running Klippy directly on its X2000E Linux host.
It does **not** contain or flash printer-MCU firmware.

The production payload is built from the commit in
`upstream-klipper.lock`, with the commissioned four-channel F001/HX711 host
overlay and an X2000E `c_helper.so` linked against the preserved Creality
glibc 2.29 runtime. `release/release.manifest` binds the payload to the exact
live configuration and exact main, nozzle, and leveling MCU dictionaries used
by the static compatibility gate.

The printer-side transaction refuses candidate releases, active or paused
prints, nonzero heater targets or power, checksum failures, a missing
four-channel overlay, missing Python dependencies, any declared MCU firmware
action, or a payload that did not pass the live-config/dictionary gate. It
swaps only `/usr/data/klipper-mainline`, waits for Klippy to return Ready, and
automatically restores the prior tree if startup fails.

## Building a candidate

1. Fetch the desired official `Klipper3d/klipper` commit and put its full SHA
   in `upstream-klipper.lock`.
2. If `klippy/chelper` changed, run the parent project's
   `tools/x2000e-host/build-c-helper.sh` against the preserved
   `F001_V1.2.3.23.ingenic` rootfs. The build enforces MIPS32r2/o32,
   hard-float FP64, NaN2008, ELF ABI version 3, a SysV hash table, and glibc
   2.29 symbol compatibility.
3. Run `build-release.sh` as a candidate. The build stops if upstream changed
   `hx71x.py`; that change requires an explicit overlay rebase and probe
   recommissioning review.
4. Generate the full live config against the saved dictionaries. Only after
   that passes, rerun with `RELEASE_CHANNEL=production`,
   `CONFIG_VALIDATION=pass`, and the four SHA256 validation inputs.
5. Commit the production `release/` directory to the `release` branch. The
   printer's Moonraker update button follows only that branch.

`build-candidate.yml` automates official-upstream fetching and candidate
assembly when the existing X2000E helper still matches Klipper's chelper
source tree. If chelper changed, it deliberately stops and requires the exact
runtime cross-build above. It never promotes a candidate to production.

## Rollback

Every successful transaction records its prior tree below
`/usr/data/e3v3p-update-state/backups/`. Moonraker's repository rollback
selects the prior controller release; the same guarded service then installs
that release. The original full pre-update tree is also retained in the first
backup made by this updater.
