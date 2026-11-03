from __future__ import annotations

import argparse
import copy
import ctypes
import json
import os
import re
import subprocess
import uuid
from pathlib import Path

from kit import ROOT, Refused, read_json, run_id, sha256, utc_now

CLASS = r"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
PREFIX = "HKEY_LOCAL_MACHINE\\" + CLASS
VALUE_NAME = "EnableGpuFirmware"
ABSENT = {"exists": False, "type": None, "data": None}
ENABLED = {"exists": True, "type": "DWord", "data": 1}
BACKUP = "p2-gsp-backup.json"
INTENT = "p2-gsp-apply-intent.json"
APPLY_SUCCESS = "p2-gsp-apply-success.json"
TARGET = None
DEVICE = PNP_DEVICE = re.compile(r"(?!)")


def configure_target(value):
    global TARGET, DEVICE, PNP_DEVICE
    from kit import gpu_target
    TARGET = gpu_target(value)
    subsystem = re.escape(TARGET['subsystem_id'])
    DEVICE = re.compile(r"^pci\\ven_10de&dev_1e04(?:&subsys_" + subsystem + r")?(?:&rev_[0-9a-f]{2})?$", re.I)
    PNP_DEVICE = re.compile(r"^pci\\ven_10de&dev_1e04&subsys_" + subsystem + r"(?:&rev_[0-9a-f]{2})?$", re.I)


KINDS = {0: "None", 1: "String", 2: "ExpandString", 3: "Binary", 4: "DWord",
         5: "DWordBigEndian", 6: "Link", 7: "MultiString", 8: "ResourceList",
         9: "FullResourceDescriptor", 10: "ResourceRequirementsList", 11: "QWord"}
BINARY_KINDS = {"None", "Binary", "DWordBigEndian", "Link", "ResourceList",
                "FullResourceDescriptor", "ResourceRequirementsList"}


def create_json(path: Path, value: dict) -> None:
    """CreateNew, flush and close before permitting any registry mutation."""
    with path.open("x", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, ensure_ascii=True, indent=2, allow_nan=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def commit_backup(path: Path, value: dict) -> None:
    """Publish one validated recovery/authorization record before any write.

    The temporary file is on the same volume. Windows rename is atomic and
    refuses an existing destination, including a concurrent transaction.
    """
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        create_json(temporary, value)
        recovered = read_json(temporary)
        validate_backup(recovered)
        if recovered != value:
            raise Refused('Recovery record readback mismatch')
        temporary.rename(path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_value(value: dict) -> None:
    if not isinstance(value, dict) or set(value) != {"exists", "type", "data"}:
        raise Refused("Invalid original registry snapshot")
    if value == ABSENT and value["exists"] is False:
        return
    if value.get("exists") is not True:
        raise Refused("Invalid registry presence")
    kind, data = value["type"], value["data"]
    valid = False
    if kind in ("DWord", "QWord"):
        valid = type(data) is int and 0 <= data < 2 ** (32 if kind == "DWord" else 64)
    elif kind in ("String", "ExpandString"):
        valid = isinstance(data, str)
    elif kind == "MultiString":
        valid = isinstance(data, list) and all(isinstance(item, str) for item in data)
    elif kind in BINARY_KINDS:
        valid = (isinstance(data, dict) and set(data) == {"hex"}
                 and isinstance(data["hex"], str) and re.fullmatch(r"(?:[0-9a-f]{2})*", data["hex"]) is not None)
    if not valid:
        raise Refused("Unsupported registry type or invalid data")


def select_target(registry) -> dict:
    if TARGET is None:
        raise Refused("Explicit GPU target is required")
    matches = [item for item in registry.adapters() if DEVICE.fullmatch(item.get("matching_device_id", ""))]
    if len(matches) != 1:
        raise Refused(f"Exactly one matching adapter is required; found {len(matches)}")
    target = matches[0]
    if not re.fullmatch(re.escape(PREFIX) + r"\\[0-9]{4}", target.get("key", ""), re.I):
        raise Refused("Unexpected display class registry key")
    require_present_target(registry, target)
    return target


def require_present_target(registry, target):
    present = [item for item in registry.present_devices()
               if PNP_DEVICE.fullmatch(str(item.get("instance_id", "")).rsplit("\\", 1)[0])]
    if len(present) != 1 or present[0]["instance_id"].lower() != TARGET["pnp_instance_id"].lower() or str(present[0].get("driver_key", "")).lower() != target["key"].lower():
        raise Refused("Present PnP driver key does not match the target class key")


def require_admin(registry) -> None:
    if not registry.is_admin():
        raise Refused("Administrator privileges are required; nothing was done")


def validate_backup(backup: dict) -> None:
    if backup.get("schema_version") != 2 or backup.get("operation") != "p2-gsp-backup":
        raise Refused("Unrecognized P2 backup")
    target = backup.get("adapter", {})
    if not DEVICE.fullmatch(target.get("matching_device_id", "")) or not re.fullmatch(
            re.escape(PREFIX) + r"\\[0-9]{4}", target.get("key", ""), re.I):
        raise Refused("Backup adapter identity mismatch")
    validate_value(backup.get("original"))
    if backup.get("intended") != ENABLED:
        raise Refused("Backup intended value mismatch")
    if backup['schema_version'] == 2:
        if (backup.get('write_authorized') is not True or backup.get('value_name') != VALUE_NAME
                or backup.get('original') != ABSENT
                or backup.get('gpu') != TARGET
                or re.fullmatch(r'\d{4}-\d\d-\d\dT.+(?:Z|\+00:00)', str(backup.get('created_at_utc', ''))) is None
                or not isinstance(backup.get('present_device'), dict)
                or PNP_DEVICE.fullmatch(str(backup['present_device'].get('instance_id', '')).rsplit('\\', 1)[0]) is None
                or str(backup['present_device'].get('driver_key', '')).lower() != target['key'].lower()):
            raise Refused('Invalid atomic recovery/write authorization record')


def load_recovery(backup_path: Path, intent_path: Path) -> dict:
    backup = read_json(backup_path)
    validate_backup(backup)
    if backup['schema_version'] == 1:
        intent = read_json(intent_path)
        if (intent.get('operation') != 'p2-gsp-apply-write-intent'
                or intent.get('backup_sha256') != sha256(backup_path)):
            raise Refused('No matching apply write intent; backup alone grants no ownership')
    return backup


def preflight(registry, reports: Path) -> dict:
    """Non-admin observation only; never enters operate or calls write_if."""
    result = {'operation': 'p2-gsp-preflight', 'observed_at_utc': utc_now(),
              'adapter': None, 'present_devices': None, 'current': None,
              'intended': dict(ENABLED), 'backup_path': str(reports / BACKUP),
              'read_only': True, 'registry_write_attempted': False,
              'settings_changed': False, 'restart_performed': False}
    try:
        result['adapters'] = registry.adapters()
        result['present_devices'] = registry.present_devices()
        # Select from the observations without issuing different PnP queries.
        class Observation:
            def adapters(self):
                return result['adapters']

            def present_devices(self):
                return result['present_devices']
        result['adapter'] = select_target(Observation())
        result['current'] = registry.read(result['adapter']['key'])
        validate_value(result['current'])
        result['status'] = 'ready' if result['current'] == ABSENT else ('already-enabled' if result['current'] == ENABLED else 'blocked')
        if result['current'] == ABSENT:
            result['enable_plan'] = {'operation': 'gsp-enable-plan-only', 'intended_value': ENABLED,
                'gpu': TARGET, 'backup': {'key': result['adapter']['key'], 'value': ABSENT,
                'target': {'pci_vendor': '10de', 'pci_device': '1e04',
                           'subsystem_vendor': TARGET['subsystem_id'][4:], 'subsystem_device': TARGET['subsystem_id'][:4]}}}
    except Exception as exc:
        result.update(status='blocked', error=str(exc))
    reports.mkdir(parents=True, exist_ok=True)
    path = reports / ('p2-preflight-' + run_id() + '.json')
    result['report_path'] = str(path)
    create_json(path, result)
    return result


def operate(registry, reports: Path, mode: str, plan_path: Path) -> dict:
    # No filesystem reads/writes or registry enumeration before this check.
    require_admin(registry)
    if mode not in ("apply", "restore"):
        raise Refused("Unsupported operation")
    adapter = select_target(registry)
    original = registry.read(adapter["key"])
    validate_value(original)
    reports.mkdir(parents=True, exist_ok=True)
    backup_path, intent_path = reports / BACKUP, reports / INTENT
    result = {"operation": "p2-gsp-" + mode, "observed_at_utc": utc_now(),
              "adapter": adapter, "before": original, "registry_write_attempted": False,
              "original": copy.deepcopy(original), "registry_write_succeeded": False,
              "restart_performed": False, "gpu_unlock_executed": False}
    receipt_path = reports / ("p2-gsp-" + mode + "-" + run_id() + ".json")
    try:
        if mode == "apply":
            plan = read_json(plan_path)
            plan = plan.get("enable_plan", plan)
            snapshot = plan.get("backup", {})
            target = snapshot.get("target", {})
            if (plan.get("gpu") != TARGET or plan.get("operation") != "gsp-enable-plan-only" or snapshot.get("value") != ABSENT
                    or plan.get("intended_value") != ENABLED
                    or any(str(target.get(k, "")).lower() != v for k, v in {
                        "pci_vendor": "10de", "pci_device": "1e04",
                        "subsystem_vendor": TARGET["subsystem_id"][4:].lower(), "subsystem_device": TARGET["subsystem_id"][:4].lower()}.items())
                    or snapshot.get("key", "").lower() != adapter["key"].lower()):
                raise Refused("The preflight plan must identify this key and an absent original value")
            if original != snapshot["value"]:
                raise Refused("Current value differs from the plan's original absence")
            if backup_path.exists():
                backup = load_recovery(backup_path, intent_path)
                if backup['schema_version'] != 2 or backup['adapter'] != adapter:
                    raise Refused('Existing backup is not a matching retryable recovery record')
            elif intent_path.exists() or (reports / APPLY_SUCCESS).exists():
                raise Refused('Existing apply records without recovery record')
            desired = ENABLED
        else:
            backup = load_recovery(backup_path, intent_path)
            if backup["adapter"] != adapter:
                raise Refused("Adapter changed since backup")
            if original != ENABLED and not (backup['schema_version'] == 2 and original == ABSENT):
                raise Refused("Restore conflict: current value is not the owned DWORD 1")
            desired = backup["original"]
        # Re-enumerate immediately before opening the target for a conditional write.
        if select_target(registry) != adapter:
            raise Refused("Adapter changed before write")
        if registry.read(adapter["key"]) != original:
            raise Refused("Registry value changed before write")
        if mode == "apply" and not backup_path.exists():
            backup = {"schema_version": 2, "operation": "p2-gsp-backup", "adapter": adapter,
                      "original": copy.deepcopy(original), "intended": ENABLED,
                      "created_at_utc": utc_now(), "plan_path": str(plan_path),
                      "value_name": VALUE_NAME, "write_authorized": True,
                      "gpu": TARGET, "present_device": next(item for item in registry.present_devices()
                                             if str(item.get('driver_key', '')).lower() == adapter['key'].lower()
                                             and PNP_DEVICE.fullmatch(str(item.get('instance_id', '')).rsplit('\\', 1)[0]))}
            commit_backup(backup_path, backup)
        result['backup_path'] = str(backup_path)
        result['backup_sha256'] = sha256(backup_path)
        # Re-read authorization before write, including retries after interruption.
        if load_recovery(backup_path, intent_path)['adapter'] != adapter:
            raise Refused('Recovery adapter changed before write')
        if original == desired:
            result['after'] = original
            result['already_restored'] = True
        else:
            result["registry_write_attempted"] = True
            # The adapter checks identity and expected type/data again on the writable handle.
            result["after"] = registry.write_if(adapter, original, desired)
        if result["after"] != desired or registry.read(adapter["key"]) != desired:
            raise Refused("Registry readback mismatch; use the retained backup for recovery")
        result["registry_write_succeeded"] = result['registry_write_attempted']
        result["status"] = "verified"
    except Exception as exc:
        result["status"] = "failed"
        result["error"] = str(exc)
        result["settings_may_have_changed"] = result["registry_write_attempted"]
        if mode == "apply" and not result["registry_write_attempted"]:
            receipt_path = reports / ("p2-gsp-refused-observation-" + run_id() + ".json")
        try:
            result["after_failure"] = registry.read(adapter["key"])
        except Exception as read_error:
            result["after_failure_error"] = str(read_error)
        try:
            create_json(receipt_path, result)
        except Exception as receipt_error:
            raise Refused(f"{exc}; receipt could not be saved: {receipt_error}; backup retained") from exc
        raise Refused(f"{exc}; receipt: {receipt_path}") from exc
    # A failed receipt write must never claim the verified registry change did not occur.
    if mode == "apply" and not (reports / APPLY_SUCCESS).exists():
        receipt_path = reports / APPLY_SUCCESS
    try:
        create_json(receipt_path, result)
    except Exception as exc:
        raise Refused(f"Registry readback verified, but receipt failed: {exc}; backup retained") from exc
    return {**result, "receipt_path": str(receipt_path)}


class WindowsRegistry:
    """Native boundary. Tests attach an in-memory winreg substitute without importing winreg."""

    def __init__(self):
        import winreg
        self.reg = winreg

    def is_admin(self):
        return bool(ctypes.windll.shell32.IsUserAnAdmin())

    def present_devices(self):
        helper = ROOT / "scripts/P2-ReadOnly.ps1"
        target_json = json.dumps(TARGET, ensure_ascii=True).replace("'", "''")
        command = ". '" + str(helper).replace("'", "''") + "'; $gpu = '" + target_json + "' | ConvertFrom-Json; ConvertTo-Json -Depth 6 -InputObject @(Get-P2PresentDisplay -Gpu $gpu) -Compress"
        executable = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        completed = subprocess.run([str(executable), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
                                   capture_output=True, encoding="utf-8-sig", timeout=30, check=True)
        devices = json.loads(completed.stdout)
        if not isinstance(devices, list):
            raise Refused("Present PnP query did not return a device list")
        return devices

    def _open(self, key, writable=False):
        if not re.fullmatch(re.escape(PREFIX) + r"\\[0-9]{4}", key, re.I):
            raise Refused("Registry key outside target class")
        access = self.reg.KEY_QUERY_VALUE | self.reg.KEY_WOW64_64KEY
        if writable:
            access |= self.reg.KEY_SET_VALUE
        return self.reg.OpenKey(self.reg.HKEY_LOCAL_MACHINE, key.split("\\", 1)[1], 0, access)

    def adapters(self):
        r = self.reg
        result = []
        with r.OpenKey(r.HKEY_LOCAL_MACHINE, CLASS, 0, r.KEY_READ | r.KEY_WOW64_64KEY) as parent:
            # QueryInfoKey gives a finite count; enumeration/read errors fail closed.
            for index in range(r.QueryInfoKey(parent)[0]):
                name = r.EnumKey(parent, index)
                if not re.fullmatch(r"[0-9]{4}", name):
                    continue
                key = PREFIX + "\\" + name
                with self._open(key) as handle:
                    try:
                        matching, kind = r.QueryValueEx(handle, "MatchingDeviceId")
                    except FileNotFoundError:
                        continue
                    if kind not in (r.REG_SZ, r.REG_EXPAND_SZ) or not isinstance(matching, str):
                        raise Refused("Invalid MatchingDeviceId type")
                    result.append({"key": key, "matching_device_id": matching.lower()})
        return result

    def _read_handle(self, handle):
        try:
            data, kind = self.reg.QueryValueEx(handle, VALUE_NAME)
        except FileNotFoundError:
            return dict(ABSENT)
        value = {"exists": True, "type": KINDS.get(kind, f"RegistryType#{kind}"),
                 "data": {"hex": data.hex()} if isinstance(data, bytes) else data}
        validate_value(value)
        return value

    def read(self, key):
        with self._open(key) as handle:
            return self._read_handle(handle)

    def write_if(self, adapter, expected, desired):
        validate_value(desired)
        require_present_target(self, adapter)
        with self._open(adapter["key"], writable=True) as handle:
            matching, kind = self.reg.QueryValueEx(handle, "MatchingDeviceId")
            if (kind not in (self.reg.REG_SZ, self.reg.REG_EXPAND_SZ)
                    or matching.lower() != adapter["matching_device_id"]
                    or self._read_handle(handle) != expected):
                raise Refused("Registry conflict on writable handle")
            if desired["exists"]:
                kind = next(k for k, name in KINDS.items() if name == desired["type"])
                data = desired["data"]
                if desired["type"] in BINARY_KINDS:
                    data = bytes.fromhex(data["hex"])
                self.reg.SetValueEx(handle, VALUE_NAME, 0, kind, data)
            else:
                self.reg.DeleteValue(handle, VALUE_NAME)
            self.reg.FlushKey(handle)
            return self._read_handle(handle)


def main(argv=None):
    from kit import environment, setting, local_path
    parser = argparse.ArgumentParser(description="GSP transaction; never reboots")
    parser.add_argument('mode', choices=('apply', 'restore', 'preflight'))
    parser.add_argument('--config', type=Path)
    parser.add_argument('--gpu-json')
    parser.add_argument('--reports')
    parser.add_argument('--plan')
    parser.add_argument('--confirm')
    args = parser.parse_args(argv)
    try:
        config = environment(args.config)
        configure_target(json.loads(args.gpu_json) if args.gpu_json is not None else config.get('gpu'))
        reports = local_path(setting(config, 'reports_dir', args.reports, 'reports'))
        plan = local_path(setting(config, 'gsp_plan', args.plan)) if args.mode == 'apply' else reports / 'unused'
        if args.mode != 'preflight':
            expected = ('ENABLE GSP ' if args.mode == 'apply' else 'RESTORE GSP ') + TARGET['uuid']
            if args.confirm != expected:
                raise Refused('Explicit confirmation required: ' + expected)
        registry = WindowsRegistry()
        result = preflight(registry, reports) if args.mode == 'preflight' else operate(registry, reports, args.mode, plan)
        print(json.dumps(result, ensure_ascii=True, indent=2))
        return 2 if result.get('status') == 'blocked' else 0
    except Exception as exc:
        print(json.dumps({'status': 'failed', 'error': str(exc), 'restart_performed': False}, ensure_ascii=True))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
