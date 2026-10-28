#!/usr/bin/env python3
"""Tests for the pinned one-time transition boundary. No real user data or network."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('migration', ROOT/'libexec/ocmac-migrate.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class MigrationTest(unittest.TestCase):
    def setUp(self):
        t=tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup); self.home=Path(t.name)
        self.code=b'print("transition fixture")\n'; self.digest=hashlib.sha256(self.code).hexdigest()
    def test_checksum_rejects_modified_code(self):
        with self.assertRaisesRegex(ValueError,'checksum'): m.verify(self.code+b'changed',self.digest)
    def test_verified_cache_and_no_automatic_download(self):
        with patch.object(m,'SCRIPT',('test',self.digest)),patch.object(m,'download',return_value=self.code) as download:
            self.assertIsNone(m.load_script(self.home));download.assert_not_called()
            self.assertEqual(m.load_script(self.home,True),self.code);download.assert_called_once()
            self.assertEqual(m.load_script(self.home),self.code);download.assert_called_once()
            self.assertEqual(m.cache_path(self.home).stat().st_mode & 0o777,0o600)
    def test_changed_cache_refused_before_execution(self):
        c=m.cache_path(self.home);c.parent.mkdir(parents=True);c.write_bytes(b'modified')
        with patch.object(m,'SCRIPT',('test',self.digest)):
            with self.assertRaisesRegex(ValueError,'checksum'):m.load_script(self.home)
    def test_symlink_cache_refused(self):
        c=m.cache_path(self.home);c.parent.mkdir(parents=True);c.symlink_to(self.home/'other')
        with self.assertRaisesRegex(ValueError,'symbolic'):m.load_script(self.home)
    def test_verified_bytes_go_to_stdin(self):
        with patch.object(m.subprocess,'run') as run:
            run.return_value.returncode=0;m.run_transition(self.code,'prepare')
            self.assertEqual(run.call_args.args[0],['/usr/bin/python3','-','prepare'])
            self.assertEqual(run.call_args.kwargs['input'],self.code)
    def test_success_removes_cache(self):
        c=m.cache_path(self.home);c.parent.mkdir(parents=True);c.write_bytes(self.code)
        with patch.object(m.os,'geteuid',return_value=501),patch.object(m.Path,'home',return_value=self.home),patch.object(m,'SCRIPT',('test',self.digest)),patch.object(m,'run_transition',return_value=0),patch.object(m,'cleanup_package'),patch.object(m.sys,'argv',['migration','restore-app','/test/ocmac']):
            self.assertEqual(m.main(),0)
        self.assertTrue(m.completion(self.home).is_file());self.assertFalse(c.exists())
    def test_root_setup_requires_preparation_before_any_system_change(self):
        from types import SimpleNamespace
        with patch.object(m.os,'geteuid',return_value=0),patch.dict(m.os.environ,{'SUDO_USER':'test-user'}),patch.object(m.pwd,'getpwnam',return_value=SimpleNamespace(pw_dir=str(self.home))),patch.object(m.sys,'argv',['migration','prepare']),patch.object(m,'run_transition') as run:
            with self.assertRaisesRegex(ValueError,'without sudo'):m.main()
            run.assert_not_called()
    def test_failed_transition_can_be_retried(self):
        c=m.cache_path(self.home);c.parent.mkdir(parents=True);c.write_bytes(self.code)
        with patch.object(m.os,'geteuid',return_value=501),patch.object(m.Path,'home',return_value=self.home),patch.object(m,'SCRIPT',('test',self.digest)),patch.object(m,'run_transition',return_value=1),patch.object(m,'cleanup_package') as cleanup,patch.object(m.sys,'argv',['migration','restore-app','/test/ocmac']):
            self.assertEqual(m.main(),1);cleanup.assert_not_called()
        self.assertTrue(c.exists());self.assertFalse(m.completion(self.home).exists())

if __name__=='__main__':unittest.main(verbosity=2)
