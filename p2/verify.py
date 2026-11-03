from __future__ import annotations

import argparse
import base64
import json
import ntpath
import os
import re
import sys
import traceback
from datetime import datetime
from pathlib import Path

from kit import ROOT, run_id
from p2.gsp import create_json, ENABLED
from kit import gpu_target
from p2.smi import versions


def trusted_smi(executable: dict) -> bool:
    if not os.environ.get('SystemRoot'):
        return False
    signature = executable.get('signature') or {}
    subject = signature.get('subject') or ''
    nvidia = re.search(r'(?:^|,\s*)O=NVIDIA Corporation(?:,|$)', subject, re.I)
    whql = (re.search(r'(?:^|,\s*)CN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)', subject, re.I)
            and re.search(r'(?:^|,\s*)O=Microsoft Corporation(?:,|$)', subject, re.I))
    root = ntpath.normpath(os.environ.get('SystemRoot', ''))
    path = ntpath.normpath(executable.get('path') or '')
    system = root + r'\System32\nvidia-smi.exe'
    store = re.escape(root + '\\System32\\DriverStore\\FileRepository\\')
    allowed_path = (path.lower() == system.lower()
                    or re.fullmatch(store + r'nv_dispi\.inf_[^\\]+\\nvidia-smi\.exe', path, re.I) is not None)
    return bool(executable.get('trusted') is True and allowed_path
                and signature.get('status') == 'Valid' and (nvidia or whql))


def assess(snapshot: dict) -> dict:
    """Unknown readings and missing target binding never establish GSP mode."""
    raw = snapshot.get("nvidia_smi_q") or ""
    try:
        driver_value, gsp_value = versions(raw)
        driver, gsp = [driver_value], [gsp_value]
    except ValueError:
        driver, gsp = [], []
    try:
        target = gpu_target(snapshot.get('gpu'))
    except Exception:
        target = None
    smi_target = snapshot.get('nvidia_smi_target') or {}
    smi_identity = bool(target and str(smi_target.get('pci_device_id', '')).lower() == '0x1e0410de'
        and str(smi_target.get('pci_sub_device_id', '')).lower() == '0x' + target['subsystem_id'].lower()
        and str(smi_target.get('uuid', '')).lower() == target['uuid'].lower())
    executable = snapshot.get("nvidia_smi_executable") or {}
    trusted = trusted_smi(executable)
    firmware_ok = (trusted and snapshot.get("nvidia_smi_exit_code") == 0 and smi_identity and len(gsp) == 1
                   and re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", gsp[0]) is not None)
    devices = snapshot.get("pnp_devices")
    pnp_ok = (isinstance(devices, list) and len(devices) == 1
              and target and str(devices[0].get("instance_id", "")).lower() == target["pnp_instance_id"].lower()
              and devices[0].get("status") == "OK"
              and type(devices[0].get("problem_code")) is int and devices[0]["problem_code"] == 0)
    tdr_count = snapshot.get("display_4101_count_since_boot")
    tdr_ok = ((snapshot.get("system_log") or {}).get("complete") is True and bool(snapshot.get("last_boot_utc")) and type(tdr_count) is int and tdr_count == 0)
    registry = snapshot.get('gsp_registry') or {}
    registry_ok = bool(pnp_ok and registry.get('value') == ENABLED
                       and registry.get('key')
                       and str(registry['key']).lower() == str(devices[0].get('driver_key', '')).lower())
    criteria = {"gsp_firmware_active": firmware_ok, "target_pnp_ok": pnp_ok,
                "tdr_since_boot_zero": tdr_ok, "target_registry_enabled": registry_ok}
    if snapshot.get('gsp_change_utc') is not None:
        try:
            boot = datetime.fromisoformat(snapshot['last_boot_utc'].replace('Z', '+00:00'))
            change = datetime.fromisoformat(snapshot['gsp_change_utc'].replace('Z', '+00:00'))
            criteria['reboot_after_kit_change'] = boot > change
        except (ValueError, TypeError, KeyError):
            criteria['reboot_after_kit_change'] = False
    return {**snapshot, "driver_version": driver[0] if len(driver) == 1 else None,
            "gsp_firmware_version": gsp[0] if len(gsp) == 1 else None,
            "code_43_present": (any(d.get("problem_code") == 43 for d in devices)
                                if isinstance(devices, list) and devices else None),
            "criteria": criteria, "unmet_criteria": [name for name, ok in criteria.items() if not ok],
            "gsp_mode_established": all(criteria.values()) and not snapshot.get("collection_errors"),
            "read_only": True, "settings_changed": False, "restart_performed": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Read-only P2 verification from a JSON file")
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    path = args.report or ROOT / 'reports' / ('p2-post-reboot-' + run_id() + '.json')
    error_path = path.with_name(path.stem + '-error.json')
    raw, snapshot = b'', None
    try:
        # Accept both PS 5.1 BOM files and the BOM-free file written by Verify-P2.
        raw = args.input.read_bytes()
        snapshot = json.loads(raw.decode('utf-8-sig'))
        if not isinstance(snapshot, dict):
            raise ValueError('JSON root must be an object')
        if snapshot.get('collection_errors'):
            raise RuntimeError('Read-only data collection failed: ' + str(snapshot['collection_errors']))
        result = assess(snapshot)
        path.parent.mkdir(parents=True, exist_ok=True)
        create_json(path, result)
        print(str(path))
        # ASCII output avoids the OEM codepage used by older consoles.
        print(json.dumps({'gsp_mode_established': result['gsp_mode_established'],
                          'unmet_criteria': result['unmet_criteria']}, indent=2))
        return 0 if result['gsp_mode_established'] else 1
    except Exception as exc:
        failure = {'status': 'tool_failed', 'input_path': str(args.input), 'snapshot': snapshot,
                   'raw_input_text': raw.decode('utf-8-sig', errors='replace'),
                   'raw_input_base64': base64.b64encode(raw).decode('ascii'),
                   'exception': {'type': type(exc).__name__, 'message': str(exc),
                                 'traceback': traceback.format_exc()},
                   'read_only': True, 'settings_changed': False, 'restart_performed': False}
        try:
            error_path.parent.mkdir(parents=True, exist_ok=True)
            create_json(error_path, failure)
        except Exception as report_error:
            print(json.dumps({'status': 'tool_failed', 'exception': failure['exception'],
                              'error_report_failure': str(report_error),
                              'retained_input_path': str(args.input)}, ensure_ascii=True), file=sys.stderr)
            return 3
        print(str(error_path))
        print(json.dumps({'status': 'tool_failed', 'exception': failure['exception']}, ensure_ascii=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
