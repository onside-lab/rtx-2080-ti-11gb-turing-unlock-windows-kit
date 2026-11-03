import contextlib
import io
import json
import unittest
from pathlib import Path
from unittest.mock import patch

import kit
from p2 import gsp
from scratch import TemporaryDirectory
from test_p2 import TARGET, MemoryRegistry
import test_p2 as fixtures
from p2.verify import assess


class ConfigTests(unittest.TestCase):
    def test_precedence(self):
        self.assertEqual(kit.setting({'key':'json'}, 'key', 'explicit', 'default'), 'explicit')
        self.assertEqual(kit.setting({'key':'json'}, 'key', default='default'), 'json')
        self.assertEqual(kit.setting({}, 'key', default='default'), 'default')

    def test_explicit_empty_and_json_empty_refuse(self):
        for data, explicit in [({'key':'json'}, ''), ({'key':''}, None), ({'key':None}, None), ({}, None)]:
            with self.subTest(data=data, explicit=explicit), self.assertRaises(kit.Refused):
                kit.setting(data, 'key', explicit)

    def test_no_implicit_gpu(self):
        for value in (None, {}, {'uuid':'GPU-abcd'}, {**TARGET,'pnp_instance_id':''}, {**TARGET,'subsystem_id':''}):
            with self.subTest(value=value), self.assertRaises(kit.Refused):
                kit.gpu_target(value)

    def test_bom_config(self):
        with TemporaryDirectory() as scratch:
            path=Path(scratch) / 'environment.local.json'
            path.write_bytes(b'\xef\xbb\xbf' + json.dumps({'gpu':TARGET}).encode())
            self.assertEqual(kit.environment(path)['gpu'], TARGET)

    def test_cli_refuses_before_native_boundary(self):
        with TemporaryDirectory() as scratch:
            config=Path(scratch) / 'environment.local.json'
            config.write_text(json.dumps({'gpu':TARGET,'gsp_plan':'unused'}))
            cases=[['apply','--config',str(config)],
                   ['restore','--config',str(config)],
                   ['apply','--config',str(config),'--confirm','wrong'],
                   ['preflight','--config',str(config),'--reports','']]
            for args in cases:
                with self.subTest(args=args), patch.object(gsp,'WindowsRegistry') as boundary, contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(gsp.main(args),2)
                    boundary.assert_not_called()

    def test_preflight_is_readonly_and_plan_drives_apply(self):
        with TemporaryDirectory() as scratch:
            gsp.configure_target(TARGET)
            registry=MemoryRegistry(admin=False)
            result=gsp.preflight(registry,Path(scratch))
            self.assertEqual(result['status'],'ready')
            self.assertNotIn('write_if',registry.calls)
            self.assertNotIn('is_admin',registry.calls)
            registry.admin=True
            applied=gsp.operate(registry,Path(scratch),'apply',Path(result['report_path']))
            self.assertEqual(applied['status'],'verified')

    def test_already_enabled_preflight_does_not_claim_ownership(self):
        with TemporaryDirectory() as scratch:
            gsp.configure_target(TARGET)
            registry=MemoryRegistry(value=gsp.ENABLED,admin=False)
            result=gsp.preflight(registry,Path(scratch))
            self.assertEqual(result['status'],'already-enabled')
            self.assertNotIn('enable_plan',result)
            self.assertFalse((Path(scratch) / gsp.BACKUP).exists())

    def test_wrong_pnp_instance_refuses(self):
        gsp.configure_target(TARGET)
        registry=MemoryRegistry()
        registry.present[0]['instance_id']=TARGET['pnp_instance_id'] + '-different'
        with self.assertRaises(kit.Refused):
            gsp.select_target(registry)

    def test_verification_requires_enabled_registry_and_reboot(self):
        fixture=fixtures.PostRebootTests()
        fixture.setUp()
        snapshot=fixture.snapshot
        for change in ({'gsp_registry':{}}, {'gsp_change_utc':'2099-01-01T00:00:00Z'}, {'gsp_change_utc':'invalid'}):
            with self.subTest(change=change):
                self.assertFalse(assess({**snapshot,**change})['gsp_mode_established'])
        self.assertTrue(assess({**snapshot,'gsp_change_utc':'2020-01-01T00:00:00Z'})['gsp_mode_established'])
