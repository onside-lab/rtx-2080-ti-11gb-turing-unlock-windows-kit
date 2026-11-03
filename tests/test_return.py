import copy
import contextlib
import io
import json
import importlib.util
import unittest
import os
from pathlib import Path
from unittest.mock import patch

from kit import sha256
from scratch import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('p3_return', ROOT / 'scripts/p3_return.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class ReturnTests(unittest.TestCase):
    def setUp(self):
        self.data = {
            'last_boot_utc': '2026-01-01T00:00:00Z',
            'system_log': {'complete': True, 'display_4101_count': 0, 'nvlddmkm_error_count': 0},
            'loader_log': {'hash_verified': True, 'fresh_from_prepared_media': True},
            'media_hashes_verified': True,
            'gpu': {'uuid': 'GPU-abcd', 'subsystem_id': 'abcd1234', 'pnp_instance_id': r'PCI\VEN_10DE&DEV_1E04&SUBSYS_ABCD1234\SYNTHETIC'},
            'nvidia_smi_target': {'uuid': 'GPU-abcd', 'pci_device_id': '0x1e0410de', 'pci_sub_device_id': '0xabcd1234'},
            'nvidia_smi_executable': {'trusted': True, 'path': str(Path(os.environ['SystemRoot']) / 'System32/nvidia-smi.exe'),
                                      'signature': {'status': 'Valid', 'subject': 'O=NVIDIA Corporation'}}, 'nvidia_smi_exit_code': 0,
            'nvidia_smi_q': (ROOT / 'tests/fixtures/smi-deprecated.txt').read_text(),
            'pnp_devices': [{'instance_id': r'PCI\VEN_10DE&DEV_1E04&SUBSYS_ABCD1234\SYNTHETIC', 'problem_code': 0, 'status': 'OK'}]}
        self.analysis = {'verdict': 'candidate-unlock-needs-windows-and-numerical-validation'}

    def test_deprecated_driver_annotation(self):
        result = collector.assess(self.data, self.analysis)
        self.assertEqual(result['driver_version'], '610.88')
        self.assertEqual(result['gsp_firmware_version'], '610.57.01')
        self.assertEqual(result['exit_code'], 0)
        self.assertFalse(result['unlock_success_established'])

    def test_crlf_and_plain_driver(self):
        for text in ('Driver Version : 610.88\r\n GSP Firmware Version : 610.57.01\r\n',
                     self.data['nvidia_smi_q'].replace('\n','\r\n')):
            with self.subTest(text=text):
                self.data['nvidia_smi_q']=text
                self.assertEqual(collector.assess(self.data,self.analysis)['driver_version'],'610.88')

    def test_duplicates_missing_and_invalid_driver_refuse(self):
        original=self.data['nvidia_smi_q']
        for text in (original + '\nDriver Version : 610.88', original + '\nGSP Firmware Version : 610.57.01',
                     'Driver Version : 610.88', 'GSP Firmware Version : 610.57.01',
                     original.replace('610.88 [Deprecated;', 'Unknown [Deprecated;'),
                     original.replace('[Deprecated;', '[Unexpected;')):
            with self.subTest(text=text), self.assertRaisesRegex(ValueError,'Driver/GSP'):
                collector.assess({**self.data,'nvidia_smi_q':text},self.analysis)

    def test_unknown_gsp_is_unmet(self):
        for value in ('N/A','Unknown','Not Supported'):
            with self.subTest(value=value):
                data={**self.data,'nvidia_smi_q':'Driver Version : 610.88\nGSP Firmware Version : ' + value}
                self.assertIn('gsp-not-active',collector.assess(data,self.analysis)['unmet_criteria'])

    def test_missing_evidence_refuses(self):
        mutations=[{'collection_errors':['denied']},{'last_boot_utc':None},{'media_hashes_verified':False},
                   {'nvidia_smi_exit_code':1},{'nvidia_smi_executable':{'trusted':True}},
                   {'nvidia_smi_target':{}},{'pnp_devices':[]},{'gpu':None},
                   {'system_log':{'complete':True,'display_4101_count':None,'nvlddmkm_error_count':0}}]
        for change in mutations:
            with self.subTest(change=change), self.assertRaises((ValueError,RuntimeError)):
                collector.assess({**self.data,**change},self.analysis)

    def test_healthy_collection_does_not_claim_unlock_or_retry(self):
        result=collector.assess(self.data,self.analysis)
        self.assertFalse(result['unlock_success_established'])
        self.assertFalse(result['numerical_validation_verified'])
        self.assertFalse(result['safe_to_retry'])

    def test_pnp_events_and_staleness_need_review(self):
        for change in ({'pnp_devices':[{**self.data['pnp_devices'][0],'problem_code':43,'status':'Error'}]},
                       {'system_log':{'complete':True,'display_4101_count':1,'nvlddmkm_error_count':0}},
                       {'loader_log':{'hash_verified':True,'fresh_from_prepared_media':False}}):
            with self.subTest(change=change):
                self.assertEqual(collector.assess({**self.data,**change},self.analysis)['exit_code'],1)

    def test_bom_stdin(self):
        value=json.dumps(self.data).encode()
        with patch.object(collector.sys,'stdin',type('Input',(),{'buffer':io.BytesIO(b'\xef\xbb\xbf'+value)})()):
            self.assertEqual(collector.read_input(None),self.data)

    def test_cli_bom_hash_checks_and_report_collision(self):
        with TemporaryDirectory() as scratch:
            folder=Path(scratch)
            log=folder / 'loader.log'
            log.write_bytes((ROOT / 'tests/fixtures/loader-synthetic.log').read_bytes())
            digest=sha256(log)
            self.data['loader_log'].update(copy=str(log),copy_sha256=digest,source_sha256_before=digest,source_sha256_after=digest)
            input_path=folder / 'input.json'
            input_path.write_bytes(b'\xef\xbb\xbf'+json.dumps(self.data).encode())
            report=folder / 'result.json'
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(collector.main(['--input',str(input_path),'--report',str(report)]),1)
                result=json.loads(report.read_text())
                self.assertEqual(result['analysis']['final_turing_values'],
                                 {'plm':0x13579bdf,'ss0':0x2468ace0,'ss1':0x12})
                self.assertEqual(result['analysis']['verdict'],'failure')
                self.assertIn('transaction-log-needs-review',result['unmet_criteria'])
                preserved=report.read_bytes()
                self.assertEqual(collector.main(['--input',str(input_path),'--report',str(report)]),2)
                self.assertEqual(report.read_bytes(),preserved)
                log.write_text('changed')
                bad_report=folder / 'bad-result.json'
                self.assertEqual(collector.main(['--input',str(input_path),'--report',str(bad_report)]),2)
            self.assertIn('hash mismatch',json.loads(bad_report.read_text())['exception']['message'])

    def test_log_failure_or_incomplete_is_not_candidate(self):
        with TemporaryDirectory() as scratch:
            log=Path(scratch) / 'loader.log'
            for text in ('TX: BEGIN\nSTOP', 'TX: BEGIN', (ROOT / 'tests/fixtures/loader-synthetic.log').read_text()+'\nTX: BEGIN'):
                with self.subTest(text=text):
                    log.write_text(text)
                    result=collector.assess(self.data,collector.analyze(log))
                    self.assertEqual(result['exit_code'],1)


if __name__ == '__main__':
    unittest.main()
