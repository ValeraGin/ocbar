#!/usr/bin/env python3
"""Synthetic migration tests: no real Keychain, launch agents, or root files."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('migration', Path(__file__).resolve().parents[1] / 'libexec/ocmac-migrate.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class FakeKeychain:
    def __init__(self): self.accounts = []
    def copy(self, account): self.accounts.append(account)

class MigrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name); self.old = self.home / '.config/ocbar'; self.new = self.home / '.config/ocmac'
        (self.old / 'profiles').mkdir(parents=True); self.kc = FakeKeychain()
    def profile(self, text=None):
        p = self.old / 'profiles/work.ocbar'
        p.write_text(text or '[Connection]\nUrl = vpn.example.test\nUser = alice\n[Auth]\nKeychainService = ru.ocbar.client\n')
        return p
    def migrate(self): return m.migrate_user(self.home, self.kc, preferences=False)
    def test_profiles_idempotency_and_originals(self):
        old = self.profile(); original = old.read_bytes(); self.migrate()
        new = self.new / 'profiles/work.ocmac'
        self.assertIn('ru.ocmac.client', new.read_text()); self.assertEqual(old.read_bytes(), original)
        self.assertEqual(self.kc.accounts, ['alice', 'totp/alice']); self.assertEqual(new.stat().st_mode & 0o777, 0o600)
        new.write_text('local edit'); self.assertEqual(self.migrate(), 'already migrated'); self.assertEqual(new.read_text(), 'local edit')
    def test_paths_and_custom_commands(self):
        text = f'[Connection]\nUrl = https://ocbar.example.test\nUser = bob\nCsdWrapper = {self.old}/csd/work.sh\n[Auth]\nRules = ~/.config/ocbar/rules\nPasswordCommand = echo ocbar\nKeychainService = custom.ocbar\n'
        self.profile(text); self.migrate(); out = (self.new / 'profiles/work.ocmac').read_text()
        self.assertIn(str(self.new) + '/csd/work.sh', out); self.assertIn('~/.config/ocmac/rules', out)
        self.assertIn('echo ocbar', out); self.assertIn('custom.ocbar', out); self.assertIn('https://ocbar.example.test', out)
        self.assertEqual(self.kc.accounts, [])
    def test_legacy_accounts(self):
        (self.old / 'profiles.conf').write_text('[one]\nurl = vpn.example.test\nuser = alice\nkeychain_service = ru.ocbar.client\n[two]\nurl = other.example.test\nuser = bob\nkeychain_service = custom\n')
        self.migrate(); self.assertEqual(self.kc.accounts, ['alice', 'totp/alice'])
    def test_conflict_does_not_overwrite(self):
        self.profile(); self.new.mkdir(); (self.new / 'keep').write_text('keep')
        with self.assertRaisesRegex(RuntimeError, 'already exists'): self.migrate()
        self.assertEqual((self.new / 'keep').read_text(), 'keep'); self.assertEqual(self.kc.accounts, [])
    def test_collision_does_not_commit(self):
        self.profile(); (self.old / 'profiles/work.ocmac').write_text('keep')
        with self.assertRaisesRegex(RuntimeError, 'collision'): self.migrate()
        self.assertFalse(self.new.exists()); self.assertEqual(self.kc.accounts, [])
    def test_symlink_refused(self):
        self.profile(); (self.old / 'external').symlink_to('/tmp')
        with self.assertRaisesRegex(RuntimeError, 'symbolic'): self.migrate()
        self.assertFalse(self.new.exists())
    def test_keychain_failure_retry(self):
        self.profile()
        with patch.object(self.kc, 'copy', side_effect=RuntimeError('locked')):
            with self.assertRaisesRegex(RuntimeError, 'locked'): self.migrate()
        self.assertFalse(self.new.exists()); self.assertTrue(self.profile().is_file())
        self.migrate(); self.assertTrue((self.new / m.MARKER).exists())
    def test_state_allowlist_and_autostart(self):
        self.profile(); state = self.home / 'Library/Application Support/ocbar'; state.mkdir(parents=True)
        for name in ['desired', 'autoconnect', 'notify.token', 'pid']: (state / name).write_text('synthetic')
        agent = self.home / 'Library/LaunchAgents/ru.ocbar.app.plist'; agent.parent.mkdir(parents=True); agent.write_text('synthetic')
        self.migrate(); target = state.with_name('ocmac')
        self.assertEqual(sorted(p.name for p in target.iterdir()), ['autoconnect', 'desired'])
        with patch.object(m, 'checked') as checked:
            m.restore_app(self.home, '/test/ocmac'); m.restore_app(self.home, '/test/ocmac')
            checked.assert_called_once_with(['/test/ocmac', 'app', 'autostart', 'on'])
    def test_preferences_merge(self):
        self.profile()
        def call(args, **kw):
            data = {'Language': 'ru', 'OldSetting': True} if m.OLD_APP in args else {'Language': 'en'}
            return subprocess.CompletedProcess(args, 0, plistlib.dumps(data), b'')
        def checked(args, **kw):
            data = plistlib.loads(Path(args[-1]).read_bytes()); self.assertEqual(data, {'Language': 'en', 'OldSetting': True})
        with patch.object(m, 'call', side_effect=call), patch.object(m, 'checked', side_effect=checked): m.migrate_user(self.home, self.kc)
        self.assertFalse((self.new / '.preferences.plist').exists())
    def test_keychain_secret_only_stdin(self):
        secret = 'test $(`) \\" value'
        calls = []
        def checked(args, **kw):
            calls.append((args, kw))
            return subprocess.CompletedProcess(args, 0, b'', b'password: 0x' + secret.encode().hex().encode() + b'\n')
        with patch.object(m.Keychain, 'has', side_effect=[False, True, True]), patch.object(m, 'checked', side_effect=checked): m.Keychain().copy('alice')
        self.assertEqual(calls[-1][0], ['/usr/bin/security', '-i']); self.assertIn(b'add-generic-password', calls[-1][1]['input'])
        self.assertNotIn(secret, str([c[0] for c in calls]))
    def test_existing_keychain_entry_not_overwritten(self):
        with patch.object(m.Keychain, 'has', return_value=True), patch.object(m, 'checked') as checked:
            m.Keychain().copy('alice'); checked.assert_not_called()
    def test_no_previous_config(self):
        self.old.rename(self.old.with_name('elsewhere')); self.assertEqual(self.migrate(), 'no previous configuration'); self.assertFalse(self.new.exists())

if __name__ == '__main__': unittest.main(verbosity=2)
