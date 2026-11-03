import copy
import unittest
from pathlib import Path
from unittest.mock import patch
import test_p2 as fixtures
from kit import Refused, read_json
from p2 import gsp

class AtomicRecoveryTests(unittest.TestCase):
    setUp = fixtures.GspTransactionTests.setUp
    apply = fixtures.GspTransactionTests.apply
    restore = fixtures.GspTransactionTests.restore

    def test_each_precommit_failure_allows_retry(self):
        real_create = gsp.create_json
        real_read = gsp.read_json
        real_rename = Path.rename
        for stage in ('partial-write', 'fsync', 'validation', 'rename'):
            with self.subTest(stage=stage):
                def create(path, data):
                    if path.name.endswith('.tmp') and stage == 'partial-write':
                        path.write_text('{', encoding='utf-8')
                        raise OSError('injected partial-write')
                    return real_create(path, data)
                def read(path):
                    if path.name.endswith('.tmp') and stage == 'validation':
                        return {}
                    return real_read(path)
                def rename(path, target):
                    if stage == 'rename':
                        raise OSError('injected rename')
                    return real_rename(path, target)
                with patch('p2.gsp.create_json', side_effect=create), patch('p2.gsp.read_json', side_effect=read), \
                     patch.object(Path, 'rename', rename), \
                     patch('p2.gsp.os.fsync', side_effect=OSError('injected fsync') if stage == 'fsync' else None):
                    with self.assertRaises(Refused):
                        self.apply()
                self.assertEqual(self.registry.value, gsp.ABSENT)
                self.assertNotIn('write_if', self.registry.calls)
                self.assertFalse((self.reports / gsp.BACKUP).exists())
                self.assertEqual(list(self.reports.glob('*.tmp')), [])
                self.assertEqual(self.apply()['status'], 'verified')
                self.assertEqual(self.restore()['after'], gsp.ABSENT)
                # Next case has its own transaction directory.
                self.reports = self.reports / stage
                self.registry.calls.clear()

    def test_committed_record_before_write_failure_allows_restore_and_retry(self):
        self.registry.write_error = OSError('before set')
        with self.assertRaises(Refused):
            self.apply()
        record = read_json(self.reports / gsp.BACKUP)
        self.assertEqual(record['schema_version'], 2)
        self.assertEqual(record['original'], gsp.ABSENT)
        self.assertTrue(record['write_authorized'])
        self.assertTrue(record['created_at_utc'])
        self.assertFalse((self.reports / gsp.INTENT).exists())
        self.assertEqual(self.restore()['status'], 'verified')
        self.registry.write_error = None
        self.assertEqual(self.apply()['status'], 'verified')

    def test_partial_write_and_success_receipt_failure_both_restore(self):
        for stage in ('flush', 'receipt'):
            with self.subTest(stage=stage):
                real_create = gsp.create_json
                def create(path, data):
                    if path.name == gsp.APPLY_SUCCESS and stage == 'receipt':
                        raise OSError('receipt denied')
                    return real_create(path, data)
                self.registry.write_error = OSError('flush') if stage == 'flush' else None
                self.registry.write_then_error = True
                with patch('p2.gsp.create_json', side_effect=create):
                    with self.assertRaises(Refused):
                        self.apply()
                self.assertEqual(self.registry.value, gsp.ENABLED)
                self.assertFalse((self.reports / gsp.APPLY_SUCCESS).exists())
                self.assertEqual(read_json(self.reports / gsp.BACKUP)['original'], gsp.ABSENT)
                self.registry.write_error = None
                self.assertEqual(self.restore()['after'], gsp.ABSENT)
                self.reports = self.reports / stage

    def test_restore_receipt_failure_can_retry_without_second_delete(self):
        self.apply()
        real_create = gsp.create_json
        def create(path, data):
            if data.get('operation') == 'p2-gsp-restore' and data.get('status') == 'verified':
                raise OSError('restore receipt denied')
            return real_create(path, data)
        with patch('p2.gsp.create_json', side_effect=create):
            with self.assertRaises(Refused):
                self.restore()
        self.assertEqual(self.registry.value, gsp.ABSENT)
        self.registry.calls.clear()
        self.assertEqual(self.restore()['status'], 'verified')
        self.assertNotIn('write_if', self.registry.calls)

    def test_orphan_temporary_file_does_not_block_retry(self):
        self.reports.mkdir()
        orphan = self.reports / (gsp.BACKUP + '.interrupted.tmp')
        orphan.write_text('{', encoding='utf-8')
        self.assertEqual(self.apply()['status'], 'verified')
        self.assertEqual(orphan.read_text(encoding='utf-8'), '{')
        self.assertEqual(self.restore()['after'], gsp.ABSENT)

    def test_corrupt_atomic_authorization_refuses_restore(self):
        self.apply()
        path = self.reports / gsp.BACKUP
        record = read_json(path)
        record['write_authorized'] = False
        path.unlink()
        gsp.create_json(path, record)
        self.registry.calls.clear()
        with self.assertRaisesRegex(Refused, 'authorization'):
            self.restore()
        self.assertNotIn('write_if', self.registry.calls)
        self.assertEqual(self.registry.value, gsp.ENABLED)

    def test_atomic_rename_collision_keeps_existing_record_and_registry(self):
        real_rename = Path.rename
        retained = b'{"concurrent_record": true}\n'
        def rename(path, target):
            target.write_bytes(retained)
            return real_rename(path, target)
        with patch.object(Path, 'rename', rename):
            with self.assertRaises(Refused):
                self.apply()
        self.assertEqual((self.reports / gsp.BACKUP).read_bytes(), retained)
        self.assertEqual(self.registry.value, gsp.ABSENT)
        self.assertNotIn('write_if', self.registry.calls)


