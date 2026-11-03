import json
import os
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

from kit import sha256
from scratch import TemporaryDirectory
from test_p2 import TARGET

ROOT = Path(__file__).resolve().parents[1]
PS = str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe')


def powershell(file, *args, cwd=ROOT, env=None):
    return subprocess.run([PS, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(file), *map(str, args)],
                          cwd=cwd, env=env, capture_output=True, encoding='utf-8-sig', errors='replace', timeout=45)


class PowerShellTests(unittest.TestCase):
    def test_configuration_precedence_and_refusals(self):
        run = powershell(ROOT / 'tests/Config.Tests.ps1', '-Root', ROOT)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        self.assertIn('"passed":true',run.stdout)

    def test_usb_refusals_and_synthetic_copy(self):
        with TemporaryDirectory() as scratch:
            run = powershell(ROOT / 'tests/P3-Mocked.Tests.ps1', '-Root', ROOT, '-Scratch', scratch)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            cases = json.loads(run.stdout)
            self.assertEqual(len(cases), 44)
            self.assertTrue(all(case['passed'] for case in cases))

    def test_volume_guid_root_calculation(self):
        run = powershell(ROOT / 'tests/P3-GuidPath.Tests.ps1', '-Root', ROOT)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue(json.loads(run.stdout)['passed'])

    def test_readonly_signature_pnp_and_event_boundaries(self):
        run = powershell(ROOT / 'tests/P2-ReadOnly.Tests.ps1')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        cases = json.loads(run.stdout)
        for key in ('system32', 'fallback', 'whql', 'fallback-whql'):
            self.assertTrue(cases[key]['value']['trusted'], key)
        for key in ('missing', 'foreign', 'invalid', 'signature-error', 'whql-invalid', 'microsoft-other', 'whql-foreign-org', 'bad-path'):
            self.assertFalse(cases[key]['value']['trusted'], key)
        for key in ('covered', 'no-events', 'tdr'):
            self.assertTrue(cases[key]['complete'], key)
        for key in ('truncated', 'cleared', 'rollover', 'clear-during', 'oldest-error', 'query-error'):
            self.assertFalse(cases[key]['complete'], key)
        self.assertEqual(cases['tdr']['display_4101_count'], 1)
        self.assertFalse(cases['pnp-present']['failed'])
        self.assertEqual(len(cases['pnp-present']['devices']), 1)
        self.assertEqual(cases['pnp-absent']['devices'], [])
        self.assertTrue(cases['pnp-missing-property']['failed'])


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for folder in ('scripts', 'config', 'reports', 'usb', 'payload'):
            (self.root / folder).mkdir()
        for file in (ROOT / 'scripts').glob('*.ps1'):
            shutil.copyfile(file, self.root / 'scripts' / file.name)
        shutil.copyfile(ROOT / 'scripts/p3_return.py', self.root / 'scripts/p3_return.py')
        shutil.copyfile(ROOT / 'kit.py', self.root / 'kit.py')
        shutil.copytree(ROOT / 'p2', self.root / 'p2', ignore=shutil.ignore_patterns('__pycache__'))
        self.config = {'gpu': {**TARGET, 'bdf': '02:00.0'}, 'reports_dir': str(self.root / 'reports'),
                       'media_policy': str(self.root / 'config/media-policy.local.json'),
                       'usb_policy': str(self.root / 'config/p3-usb-policy.local.json'),
                       'payload_root': str(self.root / 'payload')}
        self.policy = json.loads((ROOT / 'config/p3-usb-policy.example.json').read_text())
        self.policy.update(identity_sha256='a'*64, binding_sha256='b'*64,
                           volume_guid_path='\\\\?\\Volume{11111111-2222-3333-4444-555555555555}\\')
        for entry in self.policy['payload_files']:
            path = self.root / 'payload' / entry['path']
            path.parent.mkdir(exist_ok=True, parents=True)
            path.write_text('02:00.0' if entry['path'] == 'tx-select-bdf.txt' else 'SYNTHETIC ONLY: ' + entry['path'])
            entry.update(bytes=path.stat().st_size, sha256=sha256(path))
        inspect = self.root / 'reports/p3-usb-inspect-synthetic.json'
        self.save(inspect, {'synthetic': True})
        self.policy.update(inspect_report=str(inspect), inspect_sha256=sha256(inspect))
        self.save(self.root / 'config/environment.local.json', self.config)
        self.save(self.root / 'config/p3-usb-policy.local.json', self.policy)
        self.save(self.root / 'config/media-policy.local.json', {'protected_disk_identity_sha256': ['c'*64]})
        self.env = {**os.environ, 'KIT_TEST_PYTHON': sys.executable, 'PYTHONPATH': str(self.root) + os.pathsep + str(ROOT / 'tests')}

    @staticmethod
    def save(path, value):
        path.write_text(json.dumps(value), encoding='ascii')

    def run_entry(self, phase, entry, scenario='Good'):
        return powershell(ROOT / f'tests/{phase}-Entrypoints.Tests.ps1', '-FixtureRoot', self.root,
                          '-Entry', entry, '-Scenario', scenario, cwd=self.root, env=self.env)

    def test_preflight_copied_entry(self):
        run = self.run_entry('P2', 'Preflight')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        result = json.loads(next((self.root / 'reports').glob('p2-preflight-*.json')).read_text())
        self.assertTrue(result['read_only'])
        self.assertFalse(result['registry_write_attempted'])
        self.assertEqual(result['enable_plan']['gpu']['uuid'], TARGET['uuid'])

    def test_readonly_empty_target_returns_tool_error(self):
        self.save(self.root / 'config/environment.local.json',{**self.config,'gpu':None})
        for phase,entry in [('P2','Verify'),('P3','Collect')]:
            with self.subTest(entry=entry):
                run=self.run_entry(phase,entry)
                self.assertEqual(run.returncode,2,run.stdout+run.stderr)

    def test_gsp_write_confirmation_and_forwarding(self):
        capture = self.root / 'reports/python-call.json'
        for entry, verb in [('Apply', 'ENABLE'), ('Restore', 'RESTORE')]:
            for scenario in ('EmptyConfirmation', 'BadConfirmation', 'Good'):
                with self.subTest(entry=entry, scenario=scenario):
                    capture.unlink(missing_ok=True)
                    run = self.run_entry('P2', entry, scenario)
                    self.assertEqual(run.returncode, 0 if scenario == 'Good' else 2, run.stdout + run.stderr)
                    if scenario != 'Good':
                        self.assertIn('explicit-confirmation-mismatch', run.stderr)
                        self.assertFalse(capture.exists(), 'Python child called before confirmation')
                    else:
                        call = json.loads(capture.read_text())
                        arguments = call['arguments']
                        expected = ['-X', 'utf8', '-m', 'p2.gsp', entry.lower(), '--reports', str(self.root / 'reports')]
                        if entry == 'Apply':
                            expected += ['--plan', str(self.root / 'reports/synthetic-plan.json')]
                        expected += ['--confirm', verb + ' GSP ' + TARGET['uuid'], '--config']
                        self.assertEqual(arguments[:-1], expected)
                        self.assertEqual(call['input'], {'gpu': self.config['gpu']})
                        self.assertEqual(Path(call['cwd']), self.root)
                        input_path = Path(arguments[-1])
                        self.assertEqual(input_path.parent, self.root / 'reports')
                        self.assertTrue(input_path.name.startswith('.gsp-input-'))
                        self.assertFalse(input_path.exists())
                    self.assertEqual(list((self.root / 'reports').glob('.gsp-input-*')), [])

    def test_verify_copied_entry_scenarios(self):
        for scenario, expected in [('Good', 0), ('Unmet', 1), ('Bom', 0), ('LaunchFailure', 2), ('MissingReport', 2), ('CollectionFailure', 2)]:
            with self.subTest(scenario=scenario):
                run = self.run_entry('P2', 'Verify', scenario)
                self.assertEqual(run.returncode, expected, run.stdout + run.stderr)

    def test_inspect_copied_entry(self):
        run = self.run_entry('P3', 'Inspect')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        result = json.loads(next(p for p in (self.root / 'reports').glob('p3-usb-inspect-*.json') if 'synthetic' not in p.name).read_text())
        self.assertTrue(result['read_only'])

    def test_prepare_copied_entry(self):
        run = self.run_entry('P3', 'Prepare')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        receipt = json.loads(next((self.root / 'reports').glob('p3-usb-write-*.json')).read_text())
        self.assertEqual(receipt['status'], 'copy-verified')
        self.assertEqual(len(receipt['steps']), 12)
        self.assertEqual(receipt['steps'][-1]['path'], 'EFI/BOOT/BOOTX64.EFI')

    def test_prepare_refusals(self):
        for scenario in ('BadConfirmation', 'Swap', 'NoSpace'):
            with self.subTest(scenario=scenario):
                # Restore the production common file before each append-only mock injection.
                shutil.copyfile(ROOT / 'scripts/P3-Common.ps1', self.root / 'scripts/P3-Common.ps1')
                run = self.run_entry('P3', 'Prepare', scenario)
                self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
                self.assertEqual(list((self.root / 'usb').iterdir()), [])
                self.assertEqual(list((self.root / 'reports').glob('p3-usb-write-*.json')), [])

    def test_prepare_partial_failure(self):
        run = self.run_entry('P3', 'Prepare', 'CopyFailure')
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        receipt = json.loads(next((self.root / 'reports').glob('p3-usb-write-*.json')).read_text())
        self.assertEqual(receipt['status'], 'partial-failure')
        self.assertTrue(receipt['partial_files_must_not_be_booted'])

    def test_prepare_oversized_manifest_refuses_before_inventory(self):
        self.policy['payload_files'][0]['bytes'] = 4294967296
        self.save(self.root / 'config/p3-usb-policy.local.json', self.policy)
        run = self.run_entry('P3', 'Prepare', 'OversizedManifest')
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn('payload-file-exceeds-fat32-limit', run.stderr)
        self.assertEqual(list((self.root / 'usb').iterdir()), [])
        self.assertEqual(list((self.root / 'reports').glob('p3-usb-write-*.json')), [])

    def test_prepare_empty_settings_refuse_without_writes(self):
        for field in ('payload_root','usb_policy','media_policy'):
            with self.subTest(field=field):
                self.save(self.root / 'config/environment.local.json',{**self.config,field:''})
                shutil.copyfile(ROOT / 'scripts/P3-Common.ps1',self.root / 'scripts/P3-Common.ps1')
                run=self.run_entry('P3','Prepare')
                self.assertEqual(run.returncode,1,run.stdout+run.stderr)
                self.assertEqual(list((self.root / 'usb').iterdir()),[])

    def test_collect_empty_manifest_refuses(self):
        self.save(self.root / 'config/p3-usb-policy.local.json',{**self.policy,'payload_files':[]})
        run=self.run_entry('P3','Collect')
        self.assertEqual(run.returncode,2,run.stdout+run.stderr)
        result=json.loads(next((self.root / 'reports').glob('p3-return-*/result.json')).read_text())
        self.assertIn('payload-file-set',result['exception']['message'])

    def test_collect_copied_entry_scenarios(self):
        for entry in self.policy['payload_files']:
            target = self.root / 'usb' / entry['path']
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.root / 'payload' / entry['path'], target)
        shutil.copyfile(ROOT / 'tests/fixtures/loader-synthetic.log', self.root / 'usb/loader.log')
        receipt = {'created_at_utc': '2020-01-01T00:00:00Z', 'status': 'copy-verified',
                   'target': {'identity_sha256': 'a'*64, 'binding_sha256': 'b'*64, 'volume_guid_path': self.policy['volume_guid_path']},
                   'payload_files': self.policy['payload_files'], 'gpu': self.config['gpu']}
        self.save(self.root / 'reports/p3-usb-write-synthetic.json', receipt)
        # Invented register values intentionally require transaction-log review.
        for scenario, expected in [('Good',1),('Unmet',1),('Bom',1),('LaunchFailure',2),('MissingReport',2)]:
            with self.subTest(scenario=scenario):
                shutil.copyfile(ROOT / 'scripts/P3-Common.ps1', self.root / 'scripts/P3-Common.ps1')
                run = self.run_entry('P3', 'Collect', scenario)
                self.assertEqual(run.returncode, expected, run.stdout + run.stderr)
                if scenario in ('Good', 'Unmet', 'Bom'):
                    report = max((self.root / 'reports').glob('p3-return-*/result.json'), key=lambda p: p.stat().st_mtime_ns)
                    result = json.loads(report.read_text())
                    self.assertIn('transaction-log-needs-review', result['unmet_criteria'])
                    self.assertEqual(result['analysis']['final_turing_values'],
                                     {'plm': 0x13579bdf, 'ss0': 0x2468ace0, 'ss1': 0x12})
                    self.assertEqual('pnp-unhealthy' in result['unmet_criteria'], scenario == 'Unmet')

    def test_cmd_exit_codes_and_forwarding(self):
        for cmd in ROOT.glob('*.cmd'):
            shutil.copyfile(cmd, self.root / cmd.name)
            script = re.search(r'scripts\\([^" ]+\.ps1)', cmd.read_text())[1]
            (self.root / 'scripts' / script).write_text("param([int]$Code,[string]$Marker,[string]$Mode,[switch]$Preflight)\nif ($Marker -cne 'synthetic') { exit 99 }; exit $Code\n")
            for code in (0,1,2,5):
                with self.subTest(cmd=cmd.name, code=code):
                    run = subprocess.run([os.environ['COMSPEC'], '/d', '/c', str(self.root / cmd.name), '-Code', str(code), '-Marker', 'synthetic'],
                                         cwd=self.root, capture_output=True, timeout=15)
                    self.assertEqual(run.returncode, code, run.stdout + run.stderr)
