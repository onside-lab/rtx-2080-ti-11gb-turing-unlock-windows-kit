"""Small shared helpers for the Windows kit; importing performs no OS queries."""
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent


class Refused(RuntimeError):
    pass


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def run_id():
    return datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')


def read_json(path):
    value = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    if not isinstance(value, dict):
        raise Refused('JSON root must be an object')
    return value


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def environment(path=None):
    default = ROOT / 'config/environment.local.json'
    data = read_json(path or default) if path is not None or default.exists() else {}
    return data


def setting(data, key, explicit=None, default=None):
    value = explicit if explicit is not None else data.get(key, default)
    if value is None or (isinstance(value, str) and not value.strip()):
        raise Refused('Missing or empty setting: ' + key)
    return value


def local_path(value):
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def gpu_target(value):
    if not isinstance(value, dict):
        raise Refused('Explicit GPU target is required')
    for key in ('uuid', 'pnp_instance_id', 'subsystem_id'):
        setting(value, key)
    if not re.fullmatch(r'GPU-[0-9a-f-]+', value['uuid'], re.I):
        raise Refused('Invalid GPU UUID')
    if not re.fullmatch(r'[0-9a-f]{8}', value['subsystem_id'], re.I):
        raise Refused('Invalid GPU subsystem ID')
    pattern = r'PCI\\VEN_10DE&DEV_1E04&SUBSYS_' + value['subsystem_id'] + r'(?:&REV_[0-9A-F]{2})?\\[^\\]+'
    if not re.fullmatch(pattern, value['pnp_instance_id'], re.I):
        raise Refused('GPU PnP identity does not match TU102 and configured subsystem')
    return dict(value)
