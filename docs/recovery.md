# Recovery and stopping

Save this document on another device **before** changing anything. Have your
disk-encryption recovery key privately available and record original Secure
Boot, BIOS OS type, boot settings, and GSP state. Recovery is not guaranteed.
The unlock is volatile; the GSP registry change and BIOS changes are separate
and can persist after power-off.

## Abort, STOP, black screen, or driver failure

1. Stop the procedure. Do not run the unlock again in the same session after
   an abort, STOP, black screen, Code 43, TDR/display anomaly, or numerical
   failure. Missing logs or tool errors also stop the assessment.
2. Power off completely. Remove the unlock USB/memory card before the next
   startup. A warm restart or sleep/resume is not the recovery procedure
   described by this case study; account for Windows Fast Startup when ensuring
   a complete shutdown. Do not change power settings silently.
3. Boot the normal Windows Boot Manager without running the unlock. If you
   changed BIOS settings, have the human restore the recorded Secure Boot/OS
   type and boot settings as appropriate for the normal boot path. Do not
   clear Secure Boot keys, reset unrelated BIOS settings, or install boot entries.
4. If Windows starts, preserve the reports and original loader log when safely
   accessible. Record what the human actually saw, boot time, driver/PnP state,
   and errors. A failure or absent observation is not evidence of stock health.
5. Restore only a GSP setting that this kit owns, as below. Verify normal display,
   device/driver health, and the original settings after the human's restart.
   Do not use a faster benchmark as a recovery check.

If Windows still cannot boot or the display remains unavailable, use your known
Windows/vendor recovery path and the [pinned upstream recovery instructions](https://github.com/physicsdolphin/nv-uefi-unlocker/blob/9932cfbe1c2f6ebc0759139a2b0949703c00f82f/README.md).
Do not invent a motherboard-specific key sequence or repeat the unlock to try
to recover the display.

## Restore GSP in Windows

Keep the exact local environment, GPU target, and **original reports directory**.
The recovery record is `p2-gsp-backup.json` there. Preserve it, its hashes, and
all apply/restore/failure receipts. A failed apply may still have changed the
registry, including when receipt saving failed. Read `registry_write_attempted`,
`settings_may_have_changed`, and any `after_failure` evidence rather than
assuming a nonzero exit means no change occurred.

With the human's consent for this specific restoration, open an elevated
terminal at the repo root and run:

```powershell
.\Run-P2-GspRestore.cmd -Config config/environment.local.json
```

Review the PnP target and type the exact `RESTORE GSP <configured UUID>` prompt.
Restore validates this kit's ownership record, GPU and driver-key binding,
original state, and current value before changing only `EnableGpuFirmware`.
For the supported absence-to-DWORD-1 change, returning to the original state
means removing **that owned value**. This is not permission to delete the same
value from other keys or systems. A matching already-restored state may exit 0
without writing. Exit 2 means refusal/failure; preserve evidence and stop.

If the value was already DWORD 1 before this kit ran, the kit did not take
ownership and cannot restore it on your behalf. A missing/invalid backup,
changed GPU/driver key, or conflicting current value also refuses restoration.
Do not fabricate a backup, relocate it to bypass checks, or replace this refusal
with a blanket registry delete. A driver change can invalidate the binding.

After verified readback, the human restarts Windows. Use GSP preflight to
observe the original registry state and inspect actual firmware, PnP, display,
and driver/event health. `Run-P2-Verify.cmd` is an **enabled-mode** gate: restoring
original absence is not expected to pass it, and passing it does not prove
stock restoration. Check against the recorded original configuration.

## USB copy failure

An early refusal may have no receipt because no copy was attempted. If copying
began, preserve `p3-usb-write-*.json` and inspect `write_attempted`, `status`,
`steps`, and `partial_files_must_not_be_booted`. A `partial-failure`, missing
receipt, or receipt-save failure is not a bootable result, even if an EFI file
is present. **Do not boot a partial payload.**

The writer does not remove partial files, format, repartition, overwrite, or
reuse nonempty media. Stop and have the human decide how to prepare a new blank
dedicated medium outside the kit. Reinspect and review its identity, binding,
Volume GUID, and manifest; consent for the old medium does not transfer.

## Secure Boot and BIOS OS type

The human restores every setting changed for the experiment to its recorded
original value, including Secure Boot, any related OS type setting, and any
boot preference that was changed manually. Setting names are motherboard
specific; an OS type label alone is not proof of Secure Boot state. Verify the
actual state and normal Windows boot afterward. Keep the encryption recovery
key available during these changes and never paste it into reports or Discussions.

## WinRE notes

The kit's Windows entrypoints are not an offline WinRE repair tool. If online
restore is unavailable, stop automated changes. In Windows Recovery Environment,
drive letters can differ from normal Windows and the OS volume may be locked.
Identify the intended Windows installation and unlock it with your private
recovery key before considering any offline operation.

Any qualified manual repair must first match the backup's GPU/adapter key and
original value to the correct offline SYSTEM hive. Inspect `Select` to determine
the relevant ControlSet; do not assume `ControlSet001`, normal drive letters,
or that online `CurrentControlSet` addresses the offline installation. Preserve
the hive before any agreed edit. If identity, hive, ControlSet, ownership, or
current value is uncertain, do not edit it.

There is **no default registry-delete command** here. Recovery instructions do
not authorize deleting every `EnableGpuFirmware` value or modifying unrelated
adapters. Use the machine's documented recovery process or qualified local help
if the recorded conditions cannot be established. Individual support is not
provided by this repository.
