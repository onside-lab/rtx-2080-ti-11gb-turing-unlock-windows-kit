from __future__ import annotations

import copy
import json
import scratch as tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from kit import Refused, read_json, sha256
from p2 import gsp
from p2.verify import assess

SCRATCH = Path(__file__).resolve().parents[1] / '.test-scratch'
SCRATCH.mkdir(exist_ok=True)

ADAPTER = {"key": gsp.PREFIX + r"\0000",
           "matching_device_id": r"pci\ven_10de&dev_1e04&subsys_abcd1234&rev_a1"}


TARGET = {'uuid': 'GPU-abcd', 'subsystem_id': 'abcd1234',
          'pnp_instance_id': ADAPTER['matching_device_id'] + r'\4&abc'}


class MemoryRegistry:
    def __init__(self, value=None, admin=True, adapters=None):
        self.value = copy.deepcopy(gsp.ABSENT if value is None else value)
        self.admin = admin
        self.rows = copy.deepcopy([ADAPTER] if adapters is None else adapters)
        self.present = [{"instance_id": ADAPTER["matching_device_id"] + r"\4&abc", "driver_key": ADAPTER["key"]}]
        self.calls = []
        self.write_error = None
        self.write_then_error = False
        self.readback_wrong = False
        self.fail_reads_after_write = False
        self.wrote = False

    def is_admin(self):
        self.calls.append("is_admin")
        return self.admin

    def adapters(self):
        self.calls.append("adapters")
        return copy.deepcopy(self.rows)

    def present_devices(self):
        return copy.deepcopy(self.present)

    def read(self, key):
        self.calls.append("read")
        if self.wrote and self.fail_reads_after_write:
            raise OSError("read unavailable after write")
        return copy.deepcopy(self.value)

    def write_if(self, adapter, expected, desired):
        self.calls.append("write_if")
        if self.value != expected or adapter not in self.rows:
            raise Refused("concurrent change")
        if self.write_error and not self.write_then_error:
            raise self.write_error
        self.value = copy.deepcopy(desired)
        self.wrote = True
        if self.write_error:
            raise self.write_error
        if self.readback_wrong:
            return {"exists": True, "type": "DWord", "data": 9}
        return copy.deepcopy(self.value)


class GspTransactionTests(unittest.TestCase):
    def setUp(self):
        gsp.configure_target(TARGET)
        self.temp = tempfile.TemporaryDirectory(prefix="p2-fixture-", dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.reports = self.root / "reports"
        self.plan_path = self.root / "plan.json"
        self.plan = {"gpu": TARGET, "operation": "gsp-enable-plan-only", "intended_value": gsp.ENABLED,
                     "backup": {"key": ADAPTER["key"], "value": gsp.ABSENT,
                                "target": {"pci_vendor": "10de", "pci_device": "1e04",
                                           "subsystem_vendor": "1234", "subsystem_device": "abcd"}}}
        gsp.create_json(self.plan_path, self.plan)
        self.registry = MemoryRegistry()

    def apply(self):
        return gsp.operate(self.registry, self.reports, "apply", self.plan_path)

    def restore(self):
        return gsp.operate(self.registry, self.reports, "restore", self.plan_path)

    def seed_restore(self, original):
        self.reports.mkdir()
        backup = {"schema_version": 1, "operation": "p2-gsp-backup", "adapter": ADAPTER,
                  "original": original, "intended": gsp.ENABLED}
        gsp.create_json(self.reports / gsp.BACKUP, backup)
        gsp.create_json(self.reports / gsp.INTENT, {"operation": "p2-gsp-apply-write-intent",
                        "backup_sha256": sha256(self.reports / gsp.BACKUP)})
        self.registry.value = copy.deepcopy(gsp.ENABLED)

    def test_apply_absence_then_restore_deletes_only_value(self):
        applied = self.apply()
        self.assertEqual(self.registry.value, gsp.ENABLED)
        self.assertEqual(read_json(self.reports / gsp.BACKUP)["original"], gsp.ABSENT)
        self.assertEqual(applied["after"], gsp.ENABLED)
        restored = self.restore()
        self.assertEqual(restored["after"], gsp.ABSENT)
        self.assertEqual(self.registry.value, gsp.ABSENT)
        self.assertFalse(applied["restart_performed"])

    def test_existing_zero_is_observed_and_refused(self):
        self.registry.value = {"exists": True, "type": "DWord", "data": 0}
        with self.assertRaisesRegex(Refused, "original absence"):
            self.apply()
        self.assertFalse((self.reports / gsp.BACKUP).exists())
        self.assertEqual(read_json(next(self.reports.glob("p2-gsp-refused-observation-*.json")))["original"], self.registry.value)
        self.assertNotIn("write_if", self.registry.calls)
        self.assertFalse((self.reports / gsp.INTENT).exists())

    def test_existing_one_is_not_silently_accepted(self):
        self.registry.value = dict(gsp.ENABLED)
        with self.assertRaisesRegex(Refused, "original absence"):
            self.apply()
        self.assertNotIn("write_if", self.registry.calls)

    def test_wrong_original_type_is_preserved_but_apply_refused(self):
        self.registry.value = {"exists": True, "type": "String", "data": "1"}
        with self.assertRaises(Refused):
            self.apply()
        self.assertFalse((self.reports / gsp.BACKUP).exists())
        self.assertEqual(read_json(next(self.reports.glob("p2-gsp-refused-observation-*.json")))["original"], self.registry.value)
        self.assertNotIn("write_if", self.registry.calls)

    def test_non_admin_apply_does_nothing(self):
        self.registry.admin = False
        with self.assertRaisesRegex(Refused, "Administrator"):
            self.apply()
        self.assertEqual(self.registry.calls, ["is_admin"])
        self.assertFalse(self.reports.exists())

    def test_non_admin_restore_does_nothing(self):
        self.registry.admin = False
        with self.assertRaises(Refused):
            self.restore()
        self.assertEqual(self.registry.calls, ["is_admin"])
        self.assertFalse(self.reports.exists())

    def test_zero_targets_refused_before_backup(self):
        self.registry.rows = []
        with self.assertRaisesRegex(Refused, "found 0"):
            self.apply()
        self.assertFalse(self.reports.exists())

    def test_two_targets_refused_before_backup(self):
        self.registry.rows.append({**ADAPTER, "key": gsp.PREFIX + r"\0001"})
        with self.assertRaisesRegex(Refused, "found 2"):
            self.apply()
        self.assertFalse(self.reports.exists())

    def test_other_vendor_subsystem_and_partial_ids_are_excluded(self):
        for identity in (r"pci\ven_10de&dev_1e04&subsys_00001043", r"pci\ven_10de&dev_1e0",
                         r"pci\ven_10de&dev_1e040&subsys_abcd1234", r"pci\ven_8086&dev_1e04&subsys_abcd1234",
                         r"pci\ven_10de&dev_1e04&subsys_1234abcd"):
            with self.subTest(identity=identity):
                registry = MemoryRegistry(adapters=[{**ADAPTER, "matching_device_id": identity}])
                with self.assertRaises(Refused):
                    gsp.select_target(registry)

    def test_foreign_adapter_does_not_make_target_ambiguous(self):
        self.registry.rows.append({"key": gsp.PREFIX + r"\0001", "matching_device_id": r"pci\ven_8086&dev_1234"})
        self.assertEqual(self.apply()["status"], "verified")

    def test_key_outside_display_class_refused(self):
        self.registry.rows[0]["key"] = r"HKEY_LOCAL_MACHINE\SOFTWARE\0000"
        with self.assertRaises(Refused):
            self.apply()

    def test_restore_original_zero(self):
        original = {"exists": True, "type": "DWord", "data": 0}
        self.seed_restore(original)
        with self.assertRaises(Refused):
            self.restore()

    def test_restore_original_one(self):
        self.seed_restore(gsp.ENABLED)
        with self.assertRaises(Refused):
            self.restore()

    def test_restore_original_type_and_data(self):
        original = {"exists": True, "type": "ExpandString", "data": "%SystemRoot%\\value"}
        self.seed_restore(original)
        with self.assertRaises(Refused):
            self.restore()

    def test_restore_conflict_with_different_value(self):
        self.apply()
        self.registry.value = {"exists": True, "type": "DWord", "data": 0}
        self.registry.calls.clear()
        with self.assertRaisesRegex(Refused, "Restore conflict"):
            self.restore()
        self.assertNotIn("write_if", self.registry.calls)
        self.assertEqual(self.registry.value["data"], 0)

    def test_restore_conflict_with_different_type(self):
        self.apply()
        self.registry.value = {"exists": True, "type": "QWord", "data": 1}
        with self.assertRaisesRegex(Refused, "Restore conflict"):
            self.restore()
        self.assertEqual(self.registry.value["type"], "QWord")

    def test_restore_with_missing_value_is_idempotent(self):
        self.apply()
        self.registry.value = dict(gsp.ABSENT)
        self.registry.calls.clear()
        self.assertTrue(self.restore()['already_restored'])
        self.assertNotIn('write_if', self.registry.calls)

    def test_apply_twice_cannot_overwrite_original_backup(self):
        self.apply()
        before = (self.reports / gsp.BACKUP).read_bytes()
        with self.assertRaises(Refused):
            self.apply()
        self.assertEqual((self.reports / gsp.BACKUP).read_bytes(), before)

    def test_backup_without_write_intent_cannot_restore(self):
        self.seed_restore(gsp.ABSENT)
        (self.reports / gsp.INTENT).unlink()
        self.registry.calls.clear()
        with self.assertRaises(Refused):
            self.restore()
        self.assertNotIn("write_if", self.registry.calls)

    def test_backup_hash_mismatch_blocks_restore(self):
        self.seed_restore(gsp.ABSENT)
        backup = self.reports / gsp.BACKUP
        backup.write_bytes(backup.read_bytes() + b"\n")
        self.registry.calls.clear()
        with self.assertRaises(Refused):
            self.restore()
        self.assertNotIn("write_if", self.registry.calls)

    def test_adapter_key_changed_blocks_restore(self):
        self.apply()
        self.registry.rows[0]["key"] = gsp.PREFIX + r"\0002"
        self.registry.calls.clear()
        with self.assertRaisesRegex(Refused, "Present PnP"):
            self.restore()
        self.assertNotIn("write_if", self.registry.calls)

    def test_backup_write_failure_prevents_registry_write(self):
        with patch("p2.gsp.create_json", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(Refused, "disk full"):
                self.apply()
        self.assertNotIn("write_if", self.registry.calls)

    def test_atomic_record_write_failure_prevents_registry_write(self):
        real_create = gsp.create_json
        def create(path, data):
            if path.name.endswith('.tmp'):
                raise OSError("intent disk full")
            real_create(path, data)
        with patch("p2.gsp.create_json", side_effect=create):
            with self.assertRaisesRegex(Refused, "intent disk full"):
                self.apply()
        self.assertNotIn("write_if", self.registry.calls)
        self.assertFalse((self.reports / gsp.BACKUP).exists())

    def test_atomic_backup_authorization_is_durable_before_registry_write(self):
        real_write = self.registry.write_if
        def write(adapter, expected, desired):
            self.assertEqual(read_json(self.reports / gsp.BACKUP)["original"], gsp.ABSENT)
            record = read_json(self.reports / gsp.BACKUP)
            self.assertTrue(record['write_authorized'])
            self.assertEqual(record['schema_version'], 2)
            self.assertEqual(record['adapter'], adapter)
            self.assertFalse((self.reports / gsp.INTENT).exists())
            self.assertEqual(list(self.reports.glob('*.tmp')), [])
            return real_write(adapter, expected, desired)
        self.registry.write_if = write
        self.apply()

    def test_write_failure_before_change_records_failure(self):
        self.registry.write_error = OSError("access denied")
        with self.assertRaisesRegex(Refused, "access denied"):
            self.apply()
        self.assertEqual(self.registry.value, gsp.ABSENT)
        receipt = read_json(next(self.reports.glob("p2-gsp-apply-2*.json")))
        self.assertEqual(receipt["status"], "failed")
        self.assertTrue(receipt["settings_may_have_changed"])

    def test_apply_partial_write_failure_can_restore(self):
        self.registry.write_error = OSError("flush failed")
        self.registry.write_then_error = True
        with self.assertRaisesRegex(Refused, "flush failed"):
            self.apply()
        self.assertEqual(self.registry.value, gsp.ENABLED)
        self.registry.write_error = None
        self.assertEqual(self.restore()["after"], gsp.ABSENT)

    def test_restore_partial_failure_preserves_backup(self):
        self.apply()
        original_backup = (self.reports / gsp.BACKUP).read_bytes()
        self.registry.write_error = OSError("delete flush failed")
        self.registry.write_then_error = True
        with self.assertRaisesRegex(Refused, "delete flush failed"):
            self.restore()
        self.assertEqual((self.reports / gsp.BACKUP).read_bytes(), original_backup)
        self.assertEqual(self.registry.value, gsp.ABSENT)
        receipt = read_json(next(self.reports.glob("p2-gsp-restore-2*.json")))
        self.assertEqual(receipt["after_failure"], gsp.ABSENT)

    def test_wrong_readback_is_not_success(self):
        self.registry.readback_wrong = True
        with self.assertRaisesRegex(Refused, "readback mismatch"):
            self.apply()
        self.assertTrue((self.reports / gsp.BACKUP).exists())

    def test_unavailable_readback_keeps_atomic_recovery_record(self):
        self.registry.fail_reads_after_write = True
        with self.assertRaisesRegex(Refused, "read unavailable"):
            self.apply()
        self.assertTrue((self.reports / gsp.BACKUP).exists())
        self.assertTrue(read_json(self.reports / gsp.BACKUP)['write_authorized'])

    def test_receipt_failure_does_not_undo_or_hide_change(self):
        real_create = gsp.create_json
        def create(path, data):
            if data.get("status") == "verified":
                raise OSError("receipt disk full")
            real_create(path, data)
        with patch("p2.gsp.create_json", side_effect=create):
            with self.assertRaisesRegex(Refused, "readback verified, but receipt failed"):
                self.apply()
        self.assertEqual(self.registry.value, gsp.ENABLED)

    def test_value_changed_between_snapshot_and_write_blocks_apply(self):
        real_read = self.registry.read
        def read(key):
            if self.registry.calls.count("read") == 1:
                self.registry.value = {"exists": True, "type": "DWord", "data": 0}
            return real_read(key)
        self.registry.read = read
        with self.assertRaisesRegex(Refused, "changed before write"):
            self.apply()
        self.assertNotIn("write_if", self.registry.calls)

    def test_wrong_plan_value_blocks_apply_before_backup(self):
        self.plan["backup"]["value"] = dict(gsp.ENABLED)
        self.plan_path.write_text(json.dumps(self.plan), encoding="utf-8")
        with self.assertRaisesRegex(Refused, "preflight plan"):
            self.apply()
        self.assertFalse((self.reports / gsp.BACKUP).exists())
        self.assertNotIn("write_if", self.registry.calls)


class PostRebootTests(unittest.TestCase):
    def setUp(self):
        gsp.configure_target(TARGET)
        self.snapshot = {"gpu": TARGET, "nvidia_smi_q": "Driver Version : 610.88\nGSP Firmware Version : 610.88.01\n",
                         "nvidia_smi_exit_code": 0,
                         "nvidia_smi_target": {"pci_device_id": "0x1E0410DE", "pci_sub_device_id": "0xabcd1234", "uuid": "GPU-abcd"},
                         "last_boot_utc": "2026-10-31T01:00:00Z",
                         "nvidia_smi_executable": {"trusted": True, "path": str(Path(__import__("os").environ["SystemRoot"]) / "System32/nvidia-smi.exe"),
                                                   "signature": {"status": "Valid", "subject": "CN=NVIDIA Corporation, O=NVIDIA Corporation, C=US"}},
                         "system_log": {"complete": True},
                         "gsp_registry": {"key": ADAPTER['key'], "value": gsp.ENABLED},
                         "pnp_devices": [{"instance_id": ADAPTER["matching_device_id"] + r"\4&abc", "status": "OK", "problem_code": 0, "driver_key": ADAPTER['key']}],
                         "display_4101_count_since_boot": 0, "nvlddmkm_error_count_since_boot": 0}

    def test_three_requested_criteria_establish_gsp(self):
        result = assess(self.snapshot)
        self.assertTrue(result["gsp_mode_established"])
        self.assertEqual(result["driver_version"], "610.88")
        self.assertEqual(result["gsp_firmware_version"], "610.88.01")
        self.assertFalse(result["code_43_present"])
        self.assertEqual(result["unmet_criteria"], [])

    def test_gsp_na_missing_and_unknown_never_pass(self):
        for value in ("N/A", "Unknown", "", "[N/A]", "Not Supported"):
            with self.subTest(value=value):
                self.snapshot["nvidia_smi_q"] = "GSP Firmware Version : " + value
                self.assertFalse(assess(self.snapshot)["criteria"]["gsp_firmware_active"])

    def test_multiple_gsp_versions_do_not_pass(self):
        self.snapshot["nvidia_smi_q"] += "GSP Firmware Version : 610.88.01\n"
        self.assertFalse(assess(self.snapshot)["gsp_mode_established"])

    def test_other_gpu_gsp_firmware_does_not_pass(self):
        self.snapshot["nvidia_smi_target"]["pci_sub_device_id"] = "0x00001043"
        self.assertFalse(assess(self.snapshot)["gsp_mode_established"])

    def test_smi_error_never_passes_using_stale_text(self):
        self.snapshot["nvidia_smi_exit_code"] = 1
        self.assertFalse(assess(self.snapshot)["gsp_mode_established"])

    def test_code43_is_explicit(self):
        self.snapshot["pnp_devices"][0].update(status="Error", problem_code=43)
        result = assess(self.snapshot)
        self.assertTrue(result["code_43_present"])
        self.assertIn("target_pnp_ok", result["unmet_criteria"])

    def test_unknown_pnp_is_not_ok(self):
        self.snapshot["pnp_devices"] = None
        self.assertFalse(assess(self.snapshot)["criteria"]["target_pnp_ok"])
        self.assertIsNone(assess(self.snapshot)["code_43_present"])

    def test_missing_problem_code_is_not_zero(self):
        self.snapshot["pnp_devices"][0]["problem_code"] = None
        self.assertFalse(assess(self.snapshot)["criteria"]["target_pnp_ok"])

    def test_tdr_occurrence_fails(self):
        self.snapshot["display_4101_count_since_boot"] = 1
        self.assertIn("tdr_since_boot_zero", assess(self.snapshot)["unmet_criteria"])

    def test_event_query_failure_is_not_zero_events(self):
        self.snapshot["display_4101_count_since_boot"] = None
        self.assertFalse(assess(self.snapshot)["criteria"]["tdr_since_boot_zero"])

    def test_unknown_boot_time_does_not_establish_since_boot_zero(self):
        self.snapshot["last_boot_utc"] = None
        self.assertFalse(assess(self.snapshot)["gsp_mode_established"])

    def test_all_unmet_conditions_are_listed(self):
        result = assess({})
        self.assertEqual(len(result["unmet_criteria"]), 4)

    def test_secure_boot_query_denied_does_not_invent_a_value(self):
        self.snapshot["secure_boot_uefi"] = None
        self.snapshot["collection_errors"] = ["secure-boot: access denied"]
        result = assess(self.snapshot)
        self.assertIsNone(result["secure_boot_uefi"])
        self.assertFalse(result["gsp_mode_established"])


class NativeRegistryBoundaryTests(unittest.TestCase):
    class Handle:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

    class WinregFixture:
        KEY_QUERY_VALUE = 1
        KEY_SET_VALUE = 2
        KEY_WOW64_64KEY = 256
        KEY_READ = 131097
        HKEY_LOCAL_MACHINE = "fixture-HKLM"
        REG_SZ = 1
        REG_EXPAND_SZ = 2

        def __init__(self):
            self.rows = {"MatchingDeviceId": (ADAPTER["matching_device_id"], 1)}
            self.actions = []
            self.handle = NativeRegistryBoundaryTests.Handle()

        def OpenKey(self, hive, path, reserved, access):
            self.actions.append(("open", hive, path, access))
            return self.handle

        def QueryValueEx(self, handle, name):
            if name not in self.rows:
                raise FileNotFoundError(name)
            return self.rows[name]

        def SetValueEx(self, handle, name, reserved, kind, value):
            self.actions.append(("set", name, kind, value))
            self.rows[name] = (value, kind)

        def DeleteValue(self, handle, name):
            self.actions.append(("delete", name))
            del self.rows[name]

        def FlushKey(self, handle):
            self.actions.append(("flush",))

    def setUp(self):
        gsp.configure_target(TARGET)
        self.fixture = self.WinregFixture()
        # Bypass __init__: no real winreg module or Windows API is ever accessed.
        self.registry = object.__new__(gsp.WindowsRegistry)
        self.registry.reg = self.fixture
        self.present = [{"instance_id": ADAPTER["matching_device_id"] + r"\4&abc", "driver_key": ADAPTER["key"]}]
        self.registry.present_devices = lambda: copy.deepcopy(self.present)

    def test_absence_read_opens_only_query_access_in_64bit_view(self):
        self.assertEqual(self.registry.read(ADAPTER["key"]), gsp.ABSENT)
        self.assertEqual(self.fixture.actions, [("open", "fixture-HKLM", gsp.CLASS + r"\0000", 257)])

    def test_write_sets_dword_one_and_flushes_then_reads_back(self):
        self.assertEqual(self.registry.write_if(ADAPTER, gsp.ABSENT, gsp.ENABLED), gsp.ENABLED)
        self.assertIn(("set", gsp.VALUE_NAME, 4, 1), self.fixture.actions)
        self.assertEqual(self.fixture.actions[-1], ("flush",))

    def test_restore_absence_deletes_value_only(self):
        self.fixture.rows[gsp.VALUE_NAME] = (1, 4)
        self.assertEqual(self.registry.write_if(ADAPTER, gsp.ENABLED, gsp.ABSENT), gsp.ABSENT)
        self.assertIn(("delete", gsp.VALUE_NAME), self.fixture.actions)
        self.assertIn("MatchingDeviceId", self.fixture.rows)

    def test_restore_expand_string_keeps_kind_and_literal_data(self):
        self.fixture.rows[gsp.VALUE_NAME] = (1, 4)
        original = {"exists": True, "type": "ExpandString", "data": "%SystemRoot%"}
        self.assertEqual(self.registry.write_if(ADAPTER, gsp.ENABLED, original), original)
        self.assertIn(("set", gsp.VALUE_NAME, 2, "%SystemRoot%"), self.fixture.actions)

    def test_restore_binary_keeps_exact_bytes(self):
        self.fixture.rows[gsp.VALUE_NAME] = (1, 4)
        original = {"exists": True, "type": "Binary", "data": {"hex": "00ff01"}}
        self.assertEqual(self.registry.write_if(ADAPTER, gsp.ENABLED, original), original)
        self.assertIn(("set", gsp.VALUE_NAME, 3, b"\x00\xff\x01"), self.fixture.actions)

    def test_type_changed_on_writable_handle_blocks_change(self):
        self.fixture.rows[gsp.VALUE_NAME] = (1, 11)
        with self.assertRaisesRegex(Refused, "conflict on writable handle"):
            self.registry.write_if(ADAPTER, gsp.ENABLED, gsp.ABSENT)
        self.assertEqual([a[0] for a in self.fixture.actions], ["open"])

    def test_adapter_changed_on_writable_handle_blocks_change(self):
        self.fixture.rows["MatchingDeviceId"] = (r"pci\ven_10de&dev_1e04&subsys_00001043", 1)
        with self.assertRaises(Refused):
            self.registry.write_if(ADAPTER, gsp.ABSENT, gsp.ENABLED)
        self.assertEqual([a[0] for a in self.fixture.actions], ["open"])

    def test_invalid_key_never_reaches_native_open(self):
        with self.assertRaises(Refused):
            self.registry.read(r"HKEY_LOCAL_MACHINE\SYSTEM\Other\0000")
        self.assertEqual(self.fixture.actions, [])


if __name__ == "__main__":
    unittest.main()
