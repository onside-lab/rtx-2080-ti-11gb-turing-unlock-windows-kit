# Reproduce the staged procedure

Read the [tested scope and measurement limits](../README.md) and save
[recovery.md](recovery.md) on another device first. The physical result is one
RTX 2080 Ti and one unlock run, booted from a memory card in a USB reader.
The generalized kit has only mocked validation, with no hardware re-test.
These steps do not promise compatibility or the recorded performance.

Run Windows commands from the repository root. Keep a private record of the
current stage, targets, original settings, consent, report paths/hashes, and
next action. Do not proceed past an unmet gate. Reports contain identifiers,
disk inventories, and local paths; keep them private, with no recovery keys.

## 1. Create local settings and inspect

Use Python 3.11 (tested: 3.11.15) and Windows PowerShell 5.1. The initial scope
is one NVIDIA display GPU, RTX 2080 Ti `10de:1e04`. Confirm applicability against
the [tested configuration](../README.md#tested-configuration); another subsystem
or driver is not validated simply because it can be configured.

Copy these templates once, only if the local files do not already exist:

```powershell
if (-not (Test-Path -LiteralPath config/environment.local.json)) {
    Copy-Item config/environment.example.json config/environment.local.json
}
if (-not (Test-Path -LiteralPath config/media-policy.local.json)) {
    Copy-Item config/media-policy.example.json config/media-policy.local.json
}
if (-not (Test-Path -LiteralPath config/p3-usb-policy.local.json)) {
    Copy-Item config/p3-usb-policy.example.json config/p3-usb-policy.local.json
}
```

Edit the local copies from observations, without changing system settings.
Never fill identifiers by copying the tested machine or synthetic fixtures.

| Template | Fields to supply or review |
| --- | --- |
| [environment.example.json](../config/environment.example.json) | `python_executable`: your interpreter; `reports_dir`: one persistent private report directory; `gpu.uuid`, `gpu.pnp_instance_id`, `gpu.subsystem_id`, `gpu.bdf`: the observed target; `gsp_plan`: later preflight report; `media_policy`, `usb_policy`: local policy paths; `payload_root`: later verified local payload folder |
| [media-policy.example.json](../config/media-policy.example.json) | `protected_disk_identity_sha256`: a nonempty, duplicate-free list of 64-character lowercase identity hashes for disks that must never be copied to |
| [p3-usb-policy.example.json](../config/p3-usb-policy.example.json) | After inspection: `identity_sha256`, `binding_sha256`, exact `volume_guid_path`, `inspect_report`, `inspect_sha256`; later, positive byte counts and lowercase SHA-256 for every listed payload file |
| [upstream-lock.example.json](../config/upstream-lock.example.json) | Review v2.1.6 and commit `9932cfbe1c2f6ebc0759139a2b0949703c00f82f`. This is a reference pin, not a build verifier or an input consumed by the writer. |

The GPU subsystem field is the eight hex digits as reported by Windows/NVIDIA
(subsystem device followed by vendor). The PnP instance must match that subsystem
and PCI device. BDF is two hex bus digits, two device digits, and one function,
in the form `bb:dd.f`. Record UUID, present PnP instance, driver key, subsystem,
VBIOS, driver, and BDF together; stop if sources disagree. Use Windows Device
Manager/PowerShell and a trusted NVIDIA `nvidia-smi` to inspect them. Do not
install or replace a driver as an unannounced part of inspection.

Explicit arguments override JSON, which overrides safe runtime defaults. Paths
inside settings resolve against the kit root. Without `-Config`, entrypoints
look for `config/environment.local.json`. There is no default GPU or USB target.
Missing/empty required values refuse execution. Use the same `reports_dir`
throughout: GSP restore finds its ownership record there.

Inspect UEFI boot mode, Secure Boot, any BIOS OS type setting, encryption state,
normal Windows boot entry, and recovery options with the human. Record original
BIOS settings. Keep the recovery key privately at hand and confirm the recovery
instructions can be read on another device. This preflight does not collect or
validate all of those prerequisites for you.

Run the GSP registry/PnP observation, which creates a report but changes no settings:

```powershell
.\Run-P2-Preflight.cmd -Config config/environment.local.json
```

Review the printed report. `ready` means the value was absent and an
`enable_plan` is embedded; `already-enabled` means DWORD 1 was observed, without
taking ownership; `blocked` means stop. This is not running-GSP verification.

For the protected-disk list, load only the inventory helper and display its
read-only inventory before asking the selector to choose a candidate:

```powershell
. .\scripts\P3-Common.ps1
$inventory = Get-P3Inventory (Get-Location).Path
$inventory | ConvertTo-Json -Depth 16
```

Have the human identify all disks to protect, including Windows, workspace,
pagefile, recovery, and other data disks. Put their `identity_sha256` values
into the local media policy; never put the intended blank medium in that list.
Do not guess from drive letters or disk numbers alone. The code also excludes
boot/system, workspace, pagefile, ESP, reserved, and recovery media. Resolve all
inventory errors; an empty protected list is refused, not a request to format.

At this point, present a no-change inspection and plan to the human. No GSP
write, BIOS change, reboot, or USB copy belongs in this first stage.

## 2. Verify the upstream inputs and diagnostics

The user obtains upstream v2.1.6 at the pinned commit and follows its
[pinned README](https://github.com/physicsdolphin/nv-uefi-unlocker/blob/9932cfbe1c2f6ebc0759139a2b0949703c00f82f/README.md)
and diagnostic instructions. Record source/build provenance, tool versions,
features, asset origins, and hashes locally. No downloader or builder is
included here. Matching a version string or hashing locally supplied files
does not independently prove their origin or the correctness of a build.

Keep diagnostic-only EFI and TX/unlock EFI distinct. This kit's dedicated USB
writer accepts only the TX manifest described below; it does not prepare a
diagnostic-only payload or convert used diagnostic media automatically.
Arrange the pinned upstream diagnostic procedure with the human separately.
The human handles BIOS settings and one-time boot selection. Follow the
upstream Secure Boot requirements; on some boards an OS type setting affects
Secure Boot. Do not substitute a motherboard-specific setting name for a
verified observation. Record any change for restoration.

Stop if the pin, inputs, diagnostic results, physical target, or recovery path
cannot be verified. An agent must not claim it saw a BIOS/EFI screen unless the
human supplied that observation. No kit exit code replaces upstream diagnostics.

## 3. Enable GSP only if needed, reboot, and verify

If preflight returned `already-enabled`, skip the write and verify actual GSP
operation. Do not create a backup claiming ownership of a preexisting setting.
For `ready`, retain the full preflight report and use its exact path as `-Plan`
(or set `gsp_plan` to that path in the local environment). Obtain the human's
consent for this target and the change from absence to DWORD 1.

In an elevated terminal, with the actual preflight path substituted:

```powershell
.\Run-P2-GspEnable.cmd -Config config/environment.local.json -Plan "reports/p2-preflight-REPLACE.json"
```

Review the displayed PnP target and exact `ENABLE GSP <configured UUID>` prompt.
The matching authorization/backup is committed and read back **before** the
conditional `EnableGpuFirmware` write. Preserve `p2-gsp-backup.json` and all
receipts. Existing values other than DWORD 1 or absence stop the procedure;
the kit does not convert them. If an operation fails after attempting a write,
settings may have changed even if a receipt could not be saved. Stop and read
the retained recovery evidence.

The human restarts Windows. Then run:

```powershell
.\Run-P2-Verify.cmd -Config config/environment.local.json
```

Require exit 0 **and** `gsp_mode_established: true`, no unmet criteria, the
configured registry DWORD 1 bound to the present driver key, trusted NVIDIA
identity/firmware, healthy PnP, and complete since-boot event evidence. If the
kit changed GSP, the boot must be later than the backup's change timestamp.
Review driver/TDR evidence as well. Exit 1 means an assessment failed its gate;
exit 2 or above is a tool failure. Missing evidence is not success. Restore
instead of proceeding if GSP or Windows health cannot be established.

## 4. Save the baseline

In a prepared CUDA/PyTorch environment, before the unlock, run:

```powershell
python bench/gemm_bench.py --size 2048 --samples 5 --iterations 20 --warmup 10
```

Save stdout JSON privately under the report directory, using a new filename.
Record PyTorch/driver versions, GSP state, power limit, clock observations,
benchmark arguments, and background workload. Require both numerical checks
to pass. The script does not collect that system context itself. Use the same
conditions afterward; do not present a driver or power-limit change as an
unlock-only comparison. This independent script is not the original measurement
program and need not produce our numbers.

## 5. Inspect and pin the dedicated medium

Use a blank, dedicated USB device or memory card in a USB reader, with one
existing FAT32 partition/volume. The human prepares it outside this kit if
necessary; no format, repartition, or erase operation is provided. Nonempty
media is refused (except the ordinary, non-reparse `System Volume Information`
directory). Only blank dedicated media is accepted.

With the reviewed protected list:

```powershell
.\Run-P3-InspectUsb.cmd -Config config/environment.local.json
```

Require exit 0, `selection.status: identified`, one candidate, and no inventory
errors. Review its capacity, physical identity, partition, and volume with the
human. Copy the report's top-level identity and binding digests into the local
USB policy; take `volume_guid_path` from that candidate's sole volume `path`,
including its trailing backslash. JSON must escape backslashes. Never substitute
a drive letter. Set `inspect_report` to that exact saved report and compute:

```powershell
Get-FileHash -LiteralPath "reports/p3-usb-inspect-REPLACE.json" -Algorithm SHA256
```

Put the lowercase digest in `inspect_sha256`. Keep the report unchanged. A
changed medium, partition layout, volume mapping, or report requires renewed
inspection and human review; do not just replace hashes to bypass a refusal.

## 6. Review the local payload manifest and copy

Prepare the verified v2.1.6 TU10x TX payload in the local `payload_root` folder.
The [USB policy template](../config/p3-usb-policy.example.json) lists the exact
12 allowed paths. Do not add files, auto-run/armed markers, experimental markers,
or a previous `loader.log`. Each file needs a positive byte count, at most
4,294,967,295 bytes, and its SHA-256. The files themselves are not distributed.

Review `tx-select-bdf.txt` against the observed/configured GPU BDF. Review
`chain-target.txt` against this machine's intended Windows Boot Manager path
and the pinned upstream instructions. Review the other marker files and build
features against those instructions; this writer's hashes do not validate
their intended behavior or prove the EFI was built from the pinned source.

To produce a proposed manifest from the exact template paths, the following
read-only snippet prints JSON. Review the result and transfer the byte/hash
fields to the local policy; it does not populate target bindings or approve
the source files:

```powershell
@'
import hashlib, json
from pathlib import Path
from kit import environment, local_path
config = environment()
source = local_path(config['payload_root'])
policy = json.loads(Path('config/p3-usb-policy.example.json').read_text())
for entry in policy['payload_files']:
    path = source / entry['path']
    entry['bytes'] = path.stat().st_size
    with path.open('rb') as handle:
        entry['sha256'] = hashlib.file_digest(handle, 'sha256').hexdigest()
print(json.dumps(policy['payload_files'], indent=2))
'@ | python -X utf8 -
```

Confirm the recovery record is accessible, and obtain the human's consent for
copying this payload to this exact physical medium. In an elevated terminal:

```powershell
.\Run-P3-WriteUsb.cmd -Config config/environment.local.json
```

Review the displayed Volume GUID, identity, binding, and payload folder before
typing the exact `COPY USB <identity_sha256>` confirmation. The writer rechecks
source and media after confirmation, reserves 16 MiB for the loader log plus
allocation overhead, copies with CreateNew semantics, and reads hashes back.
EFI is copied last. Require exit 0 and a saved `copy-verified` receipt with
`partial_files_must_not_be_booted: false`. Keep that receipt for collection.
On partial failure, **do not boot the medium**. There is no automatic cleanup;
retain the receipt and follow [recovery](recovery.md).

## 7. Human: boot once and confirm

The human makes any agreed BIOS changes and uses the temporary UEFI boot menu
to boot this verified medium once. Do not install a boot entry or modify the
normal boot order for automation. Verify the EFI version, target, and TX
confirmation screen against the pinned procedure before proceeding.

The upstream EFI requires Space/Enter and aborts after 30 seconds without input.
The human chooses whether to confirm. No auto-run marker is allowed. On an
abort, STOP, black screen, or abnormality, do not re-run in that session: power
off completely, remove the unlock media, and boot normally. Follow recovery.

## 8. Collect, benchmark, and restore

After Windows returns, keep the prepared medium available for read-only
collection. Do not edit its payload or log. Run in an elevated terminal for
Secure Boot observation as well as Windows/USB evidence:

```powershell
.\Collect-P3Return.cmd -Config config/environment.local.json
```

Keep the printed return folder: `collection.json`, a preserved `loader.log`
when available, `result.json`, and any `tool-error.json`. Collection compares
log hashes before/during/after copying, payload hashes and the preparation
receipt, GSP, PnP/Code 43, driver, and complete since-boot event evidence.
The log freshness window is not proof that a log belongs to the current boot;
the snapshot explicitly leaves `current_boot_correlation_established` false.
The analysis commit is a pinned claim, not independent EFI build verification.

- Exit 0: `collected-candidate`. Numerical validation is still required;
  `unlock_success_established`, `numerical_validation_verified`, and
  `safe_to_retry` remain false.
- Exit 1: `collected-needs-review`. Read `unmet_criteria`; do not report success.
- Exit 2: `tool-failed`. Evidence is incomplete or the tool failed. Preserve it
  and stop; do not reinterpret collection failure as an unlock result.

Only after reviewing healthy Windows state and complete candidate evidence,
repeat the baseline benchmark command under the same conditions. Preserve the
new JSON separately, including failed numerical checks. Compare medians and
context; speed alone does not validate an unlock. Stop on any driver/display
or numerical anomaly. Do not retry the unlock in the same session.

To finish, power off completely and boot normally without the unlock medium.
Restore any kit-owned GSP change using the original reports directory, and have
the human restore changed Secure Boot/OS type settings. Use [recovery.md](recovery.md)
for the exact ownership checks and stock-state verification.

## Command contracts

All `.cmd` launchers forward arguments and preserve the child exit code. They
do not elevate or reboot automatically. Settings/collection reads can still
create local reports. `-Confirm` can supply the exact confirmation string, but
an agent must not supply it without the human's consent for that operation.
Usage/argument errors may exit 2 before a report exists.

| Entrypoint and script | Inputs | Outputs and exit codes |
| --- | --- | --- |
| [Run-P2-Preflight.cmd](../Run-P2-Preflight.cmd) → [Set-GspMode.ps1](../scripts/Set-GspMode.ps1) `-Preflight` | `-Config`, optional `-Reports`, `-Python`, `-GpuJson`; configured GPU | `p2-preflight-*.json` and stdout JSON; 0 = `ready` or `already-enabled`, 2 = blocked/tool error; no registry write |
| [Run-P2-GspEnable.cmd](../Run-P2-GspEnable.cmd) → [Start-P2.ps1](../scripts/Start-P2.ps1) `-Mode Apply` → Set-GspMode | Same common inputs, `-Plan` or `gsp_plan`, optional `-Confirm`; admin and exact target consent | `p2-gsp-backup.json`, apply/refusal receipts; first success `p2-gsp-apply-success.json`; 0 = readback verified, 2 = refusal/failure, possibly after a write |
| [Run-P2-GspRestore.cmd](../Run-P2-GspRestore.cmd) → Start-P2 `-Mode Restore` → Set-GspMode | Same config/reports/GPU, matching backup, admin, optional `-Confirm`; no plan needed | `p2-gsp-restore-*.json` or failure receipt; 0 = original state read back (possibly already restored), 2 = refusal/failure; backup retained |
| [Run-P2-Verify.cmd](../Run-P2-Verify.cmd) → [Verify-P2.ps1](../scripts/Verify-P2.ps1) | `-Config`, optional `-Reports`, `-Python`, `-GpuJson`; accepts unused `-UsbPolicy`, `-MediaPolicy` | `p2-post-reboot-*.json`, or `*-error.json`; temporary input, if created, is retained only when the error report also cannot be saved; 0 = enabled GSP established, 1 = unmet assessment, 2+ = tool/child failure |
| [Run-P3-InspectUsb.cmd](../Run-P3-InspectUsb.cmd) → [Inspect-P3Usb.ps1](../scripts/Inspect-P3Usb.ps1) | `-Config`, optional `-Reports`, `-MediaPolicy`; nonempty protected identities | `p3-usb-inspect-*.json`; 0 = one identified candidate, 1 = selection refused, 2 = tool/config failure; no media writes |
| [Run-P3-WriteUsb.cmd](../Run-P3-WriteUsb.cmd) → [Prepare-P3Usb.ps1](../scripts/Prepare-P3Usb.ps1) | `-Config`, optional `-Reports`, `-GpuJson`, `-UsbPolicy`, `-MediaPolicy`, `-Payload`, `-InspectReport`, `-InspectSha256`, `-Confirm`; admin | Media files and `p3-usb-write-*.json` once copying is attempted; 0 = `copy-verified`, 1 = refused or partial failure, 2 = receipt-save failure; early refusal may have no receipt |
| [Collect-P3Return.cmd](../Collect-P3Return.cmd) → [Collect-P3Return.ps1](../scripts/Collect-P3Return.ps1) | `-Config`, optional `-Reports`, `-Python`, `-GpuJson`, `-UsbPolicy`, `-MediaPolicy`, `-InspectReport`, `-InspectSha256`; same prepared medium/receipt | `p3-return-*/` evidence folder; 0 = candidate, 1 = needs review, 2 = tool failure; no registry/media writes |
| [gemm_bench.py](../bench/gemm_bench.py) | `--size` (2048), `--samples` (5), `--iterations` (20), `--warmup` (10); positive integers, PyTorch/CUDA | JSON to stdout, errors to stderr; 0 = completed and small checks passed, 1 = benchmark/numerical failure, 2 = missing PyTorch/CUDA or argument error; does not change unlock/GSP state |

The launchers call these internal Python interfaces:

| Module/script | Inputs | Outputs and exit codes |
| --- | --- | --- |
| [p2.gsp](../p2/gsp.py) | `preflight`, `apply`, or `restore`; `--config`, `--gpu-json`, `--reports`, `--plan`, `--confirm` as appropriate | Same GSP reports/stdout and 0/2 codes above; does not prompt, so exact `--confirm` is mandatory for writes |
| [p2.verify](../p2/verify.py) | Required `--input` collected snapshot; optional `--report` new path (otherwise a timestamped path under kit `reports`) | Assessment JSON or error report; 0 = established, 1 = unmet, 2 = tool failure, 3 = error report also could not be saved |
| [p3_return.py](../scripts/p3_return.py) | `--input` collection JSON (otherwise stdin), required `--report` new output path | Result JSON and stdout status; 0 = candidate, 1 = needs review, 2 = tool failure |

[Kit-Common.ps1](../scripts/Kit-Common.ps1), [P2-ReadOnly.ps1](../scripts/P2-ReadOnly.ps1),
and [P3-Common.ps1](../scripts/P3-Common.ps1) are loaded helpers, with no standalone
workflow or process exit-code contract. They take function arguments and return
observations/values or throw; the entrypoints above handle errors. Importing
[kit.py](../kit.py), [p2/smi.py](../p2/smi.py), and [p2/return_log.py](../p2/return_log.py)
does not perform a live inspection.
