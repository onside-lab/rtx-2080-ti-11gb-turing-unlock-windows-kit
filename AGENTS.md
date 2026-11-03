# Coding-agent entrypoint

Start with a no-change inspection and plan. Read [README](README.md),
[reproduce](docs/reproduce.md), and [recovery](docs/recovery.md) before execution.
Observation reports may be saved locally; no system setting or media changes
belong in the first inspection.

## Scope and prerequisites

- One physical RTX 2080 Ti (TU102), one unlock run, Windows 11, driver 610.88,
  GSP 610.57.01. The generalized kit has not been re-tested on hardware.
- Pin upstream v2.1.6, commit `9932cfbe1c2f6ebc0759139a2b0949703c00f82f`.
  The user supplies and verifies upstream inputs; no payload is included.
  A version string or local hash alone does not prove the EFI build's origin.
- Current checks require `10de:1e04`, a matching configured subsystem, UUID,
  PnP/driver-key binding, and one NVIDIA display GPU. Never widen these checks
  because a config field can be changed. See README for the tested subsystem.
- Know Windows PnP/registry, GSP, UEFI, disk identity/Volume GUID mapping,
  encryption recovery, and the pinned upstream diagnostic/TX distinction.
  Python 3.11.15 and Windows PowerShell 5.1 were used for mocked kit tests.
  Elevated terminals are needed for GSP writes/USB copy and some evidence.
- Have the human's recovery key available privately and recovery instructions
  on another device. Record original BIOS Secure Boot/OS type settings.

## Stages and stops

1. Inspect GPU, driver, GSP, boot/encryption state, and disks. Produce local
   configuration and an applicability plan. Stop for missing evidence,
   mismatched/ambiguous identity, multiple NVIDIA GPUs, or unknown recovery.
2. Verify the upstream pin, inputs, and diagnostic-only EFI procedure with the
   human. Diagnostic media preparation is outside this kit's TX writer.
   Stop if diagnostics cannot be verified or show any abnormality.
3. Preflight GSP. `already-enabled` means verify, without taking ownership.
   Only an absent value may become DWORD 1, with a durable matching backup.
   Obtain the human's consent for that exact target/change. The human reboots;
   then require registry, running firmware, PnP, and since-boot evidence to pass.
4. Save a baseline. Review the pinned 12-file payload manifest, protected disks,
   inspection hash, media binding, Volume GUID, and recovery path. Obtain consent
   for copying to that exact medium. Only a `copy-verified` receipt allows boot.
   The human handles BIOS, temporary boot selection, and Space/Enter confirmation.
5. Preserve/collect the log and Windows evidence. Exit 0 is candidate evidence
   only; require separate numerical validation and comparable measurements.
   Stop on collection failure, unmet criteria, STOP, black screen, PnP/TDR or
   numerical failures. Never retry in the same session; follow recovery.
6. Explain normal boot without the media, kit-owned GSP restoration, and the
   human's restoration of changed BIOS settings. Do not claim recovery succeeded
   without observations. GSP verification checks enabled mode, not stock mode.

## Never do

- Never reboot, change BIOS, or change the registry without the human's explicit
  agreement to that operation. Do not infer consent from UAC or a past target.
- Never create an auto-run/armed marker, bypass confirmation, arrange per-boot
  automation, change boot entries, or claim to have seen an unobserved screen.
- Never format, repartition, erase, overwrite files, reuse nonempty media, or
  boot a partial copy. Do not add force options to bypass refusals.
- Never delete registry values by default, edit arbitrary adapters/ControlSets,
  or restore a value without this kit's matching ownership/recovery record.
- Never publish local reports/configs, raw device identifiers, or recovery keys.

## Resume record

Keep a private local record: current stage; configured GPU and medium; exact
config/report/backup/receipt paths and hashes; human consent for each operation;
completed changes and boot times; diagnostic, GSP, Windows and benchmark results;
unmet/unknown evidence; original BIOS settings; next action and rollback path.
Keep the original reports directory for restore. Never transfer permission to a
different target or silently repeat an unlock after an interrupted session.

For repository changes, run `python -m unittest discover -s tests` from the root.
Native tests use mocked OS boundaries and separate processes; never disable
test isolation. Passing tests does not establish real-hardware compatibility.
