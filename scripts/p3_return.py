"""Read-only assessment. 0=collected/candidate, 1=collected/needs review, 2=tool failure."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from p2.smi import versions
from p2.return_log import analyze_log
from kit import gpu_target
from p2.verify import trusted_smi

COMMIT = '9932cfbe1c2f6ebc0759139a2b0949703c00f82f'


def read_input(path: Path | None) -> dict:
    # Windows PowerShell stdin may include a UTF-8 BOM. File input uses the same contract.
    raw = path.read_bytes() if path else sys.stdin.buffer.read()
    return json.loads(raw.decode('utf-8-sig'))


def analyze(path: Path) -> dict:
    return analyze_log(path.read_text(encoding='utf-8-sig'), 'transaction', COMMIT, COMMIT)


def assess(data: dict, analysis: dict) -> dict:
    if data.get('collection_errors'):
        raise ValueError('Collection incomplete: ' + repr(data['collection_errors']))
    if not data.get('last_boot_utc') or not data.get('system_log', {}).get('complete'):
        raise ValueError('Boot/event evidence unavailable')
    log = data['loader_log']
    if log.get('hash_verified') is not True or data.get('media_hashes_verified') is not True:
        raise ValueError('USB evidence unverified')
    executable = data.get('nvidia_smi_executable') or {}
    if not trusted_smi(executable) or data.get('nvidia_smi_exit_code') != 0:
        raise ValueError('nvidia-smi collection untrusted or failed')
    target = gpu_target(data.get('gpu'))
    smi = data.get('nvidia_smi_target') or {}
    if (str(smi.get('uuid', '')).lower() != target['uuid'].lower()
            or str(smi.get('pci_device_id', '')).lower() != '0x1e0410de'
            or str(smi.get('pci_sub_device_id', '')).lower() != '0x' + target['subsystem_id'].lower()):
        raise ValueError('nvidia-smi target identity mismatch')
    text = data['nvidia_smi_q']
    driver, firmware = versions(text)
    gsp = [firmware]
    devices = data.get('pnp_devices')
    if (not isinstance(devices, list) or len(devices) != 1 or type(devices[0].get('problem_code')) is not int
            or str(devices[0].get('instance_id', '')).lower() != target['pnp_instance_id'].lower()):
        raise ValueError('PnP evidence unavailable')
    unmet = []
    if not log.get('fresh_from_prepared_media'):
        unmet.append('loader-log-outside-prepared-media-window')
    if analysis['verdict'] != 'candidate-unlock-needs-windows-and-numerical-validation':
        unmet.append('transaction-log-needs-review')
    if not re.fullmatch(r'\d+(?:\.\d+)+', gsp[0]):
        unmet.append('gsp-not-active')
    if devices[0]['problem_code'] != 0 or devices[0].get('status') != 'OK':
        unmet.append('pnp-unhealthy')
    events = data['system_log']
    for key in ('display_4101_count', 'nvlddmkm_error_count'):
        if type(events.get(key)) is not int or events[key] < 0:
            raise ValueError('Event count unavailable')
        if events[key] != 0:
            unmet.append(key)
    return {'exit_code': 1 if unmet else 0,
            'status': 'collected-needs-review' if unmet else 'collected-candidate',
            'driver_version': driver, 'gsp_firmware_version': gsp[0],
            'code_43': devices[0]['problem_code'] == 43, 'unmet_criteria': unmet,
            'analysis': analysis, 'snapshot': data, 'unlock_success_established': False,
            'numerical_validation_verified': False, 'safe_to_retry': False}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args(argv)
    data = None
    try:
        data = read_input(args.input)
        if data.get('collection_errors'):
            raise ValueError('Collection incomplete: ' + repr(data['collection_errors']))
        log = data['loader_log']
        path = Path(log['copy'])
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != log['copy_sha256'] or digest != log['source_sha256_before'] or digest != log['source_sha256_after']:
            raise ValueError('Preserved loader.log hash mismatch')
        result = assess(data, analyze(path))
    except Exception as exc:
        result = {'exit_code': 2, 'status': 'tool-failed', 'exception':
                  {'type': type(exc).__name__, 'message': str(exc)}, 'snapshot': data,
                  'unlock_success_established': False, 'safe_to_retry': False}
    try:
        with args.report.open('x', encoding='utf-8', newline='\n') as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
    except OSError as exc:
        print(f'Result could not be saved: {exc}', file=sys.stderr)
        return 2
    print(json.dumps({'status': result['status'], 'report': str(args.report)}, ensure_ascii=True))
    return result['exit_code']


if __name__ == '__main__':
    raise SystemExit(main())
