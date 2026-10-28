#!/usr/bin/env python3
"""Synthetic full app-update transactions and pre-elevation CSD preparation."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'libexec'/file)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
u=module('updater','ocmac-app-update.py');p=module('preparation','ocmac-prepare.py')

def bundle(path,old=False):
    binary='previous-app' if old else 'ocmac-app'
    (path/'Contents/MacOS').mkdir(parents=True)
    (path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'ru.previous.app' if old else u.LABEL,'CFBundleExecutable':binary,'CFBundleShortVersionString':'1.0' if old else '2.0'}))
    f=path/'Contents/MacOS'/binary;f.write_text('#!/bin/sh\nexit 0\n');f.chmod(0o755)

class AppUpdateTest(unittest.TestCase):
    def setUp(self):
        t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);self.home=Path(t.name)
        self.source=self.home/'package/ocmac.app';bundle(self.source)
        self.dest=self.home/'Applications/OpenConnect for Mac.app';bundle(self.dest,True)
        self.agent=self.home/'Library/LaunchAgents/ru.previous.app.plist';self.agent.parent.mkdir(parents=True)
        self.alias=self.dest.with_name('previous.app');self.alias.symlink_to(self.dest)
        self.agent.write_bytes(plistlib.dumps({'Label':'ru.previous.app','ProgramArguments':[str(self.alias/'Contents/MacOS/previous-app')]}))
        self.calls=[];self.fail_check=False;self.fail_bootstrap=False
    def run_command(self,args):
        self.calls.append(args);code=0;out=''
        if args[0]=='/usr/bin/pgrep':code=1
        elif args[0]=='/usr/bin/diff':code=1
        elif '--installation-check' in args:
            out=json.dumps({'clientAvailable':not self.fail_check,'clientVersion':'ocmac 2.0'})
        elif self.fail_bootstrap and 'bootstrap' in args and args[-1].endswith('ru.ocmac.app.plist'):code=1
        return subprocess.CompletedProcess(args,code,out,'')
    def test_old_app_alias_and_login_item_are_replaced(self):
        with patch.object(u,'run',side_effect=self.run_command):u.update(self.source,self.home)
        self.assertEqual(u.info(self.dest)['CFBundleExecutable'],'ocmac-app')
        self.assertFalse(self.agent.exists());self.assertFalse(self.alias.exists())
        agent=plistlib.loads((self.agent.parent/'ru.ocmac.app.plist').read_bytes())
        self.assertEqual(agent['ProgramArguments'],[str(self.dest/'Contents/MacOS/ocmac-app')])
        self.assertTrue(any('--installation-check' in a for a in self.calls))
        self.assertTrue(any('bootout' in a for a in self.calls));self.assertTrue(any('bootstrap' in a for a in self.calls))
    def test_missing_client_rolls_back_app_and_login_item(self):
        self.fail_check=True;original=self.agent.read_bytes()
        with patch.object(u,'run',side_effect=self.run_command):
            with self.assertRaisesRegex(RuntimeError,'matching client'):u.update(self.source,self.home)
        self.assertEqual(u.info(self.dest)['CFBundleExecutable'],'previous-app');self.assertEqual(self.agent.read_bytes(),original)
        self.assertTrue(self.alias.exists());self.assertFalse((self.agent.parent/'ru.ocmac.app.plist').exists())
    def test_bootstrap_failure_restores_previous_app(self):
        self.fail_bootstrap=True
        with patch.object(u,'run',side_effect=self.run_command):
            with self.assertRaisesRegex(RuntimeError,'launch at login'):u.update(self.source,self.home)
        self.assertEqual(u.info(self.dest)['CFBundleExecutable'],'previous-app');self.assertTrue(self.agent.exists())
    def test_failed_staged_move_restores_previous_app(self):
        original=Path.rename
        def rename(path,target):
            if path.name=='next.app':raise OSError('staged move failed')
            return original(path,target)
        with patch.object(u,'run',side_effect=self.run_command),patch.object(Path,'rename',rename):
            with self.assertRaisesRegex(OSError,'staged move'):u.update(self.source,self.home)
        self.assertEqual(u.info(self.dest)['CFBundleExecutable'],'previous-app');self.assertTrue(self.agent.exists())
    def test_fresh_install_with_missing_client_leaves_no_app(self):
        import shutil
        shutil.rmtree(self.dest);self.alias.unlink();self.agent.unlink();self.fail_check=True
        with patch.object(u,'run',side_effect=self.run_command):
            with self.assertRaisesRegex(RuntimeError,'matching client'):u.update(self.source,self.home)
        self.assertFalse(self.dest.exists())
    def test_broken_bundle_never_stops_existing_app(self):
        (self.source/'Contents/MacOS/ocmac-app').unlink()
        with patch.object(u,'run',side_effect=self.run_command):
            with self.assertRaisesRegex(RuntimeError,'missing'):u.update(self.source,self.home)
        self.assertEqual(self.calls,[]);self.assertTrue(self.agent.exists())

class PreparationTest(unittest.TestCase):
    def setUp(self):
        t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);self.home=Path(t.name)
        self.config=self.home/'config';(self.config/'profiles').mkdir(parents=True)
        self.script=self.home/'Downloads/script $(touch marker).sh';self.script.parent.mkdir();self.script.write_text('#!/bin/sh\nexit 0\n')
        self.profile=self.config/'profiles/work.ocmac';self.profile.write_text('[Connection]\nUrl = vpn.example.test\nCsdWrapper = '+str(self.script)+'\n')
    def test_user_copy_is_stable_private_and_idempotent(self):
        self.assertEqual(p.prepare(self.config),1);self.assertEqual(p.prepare(self.config),0)
        copies=list((self.config/'csd').glob('*.sh'));self.assertEqual(len(copies),1)
        self.assertEqual(copies[0].read_bytes(),self.script.read_bytes());self.assertEqual(copies[0].stat().st_mode & 0o777,0o700)
        self.assertIn(str(copies[0]),self.profile.read_text());self.assertFalse((self.home/'marker').exists())
    def test_missing_input_does_not_partially_rewrite_profiles(self):
        before=self.profile.read_bytes();(self.config/'profiles/other.ocmac').write_text('[Connection]\nCsdWrapper = /missing/script\n')
        with self.assertRaises((OSError,ValueError)):p.prepare(self.config)
        self.assertEqual(self.profile.read_bytes(),before);self.assertFalse((self.config/'csd').exists())
    def test_target_symlink_is_refused(self):
        (self.config/'csd').symlink_to(self.home/'Downloads')
        with self.assertRaisesRegex(ValueError,'symbolic'):p.prepare(self.config)

if __name__=='__main__':unittest.main(verbosity=2)
