#!/usr/bin/env python3
"""Exercise live-runner setup with fake CLI/network operations, never a VPN."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

client = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name('macos-vpn-test.py')
spec = importlib.util.spec_from_file_location('live', client)
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
# A previous version may be loaded from a temporary directory for regression checks.
live.CLI = str(Path(__file__).resolve().parent.parent / 'bin/ocbar')


class RunnerSetup(unittest.TestCase):
    def connect_environment(self, extra=()):
        captured = {}

        class StopBeforeConnection(Exception):
            pass

        def fake_run(command, env=None, **kwargs):
            if command[:2] == ['launchctl', 'print']:
                return subprocess.CompletedProcess(command, 1, '', '')
            if command[1:3] == ['connect', 'live-test']:
                captured.update(env)
                captured['profile_text'] = (Path(env['OCBAR_CONFIG_DIR']) / 'profiles/live-test.ocbar').read_text()
                raise StopBeforeConnection()
            return subprocess.CompletedProcess(command, 0, '', '')

        source = {'PATH': '/synthetic/bin', 'https_proxy': 'http://localhost:9999',
                  'HTTPS_PROXY': 'http://localhost:9998', 'http_proxy': 'http://localhost:9997',
                  'HTTP_PROXY': 'http://localhost:9996', 'ALL_PROXY': 'socks5://localhost:9995',
                  'all_proxy': 'socks5://localhost:9994', 'NO_PROXY': '*', 'no_proxy': '*',
                  'OCBAR_CONFIG_DIR': '/do-not-use-personal-config', 'OCBAR_TEST_PASSWORD': 'stale'}
        with patch.dict(os.environ, source, clear=True), \
                patch.object(sys, 'argv', ['live', '--live', '--mode', 'proxy', *extra, 'vpn.example.test']), \
                patch.object(live, 'status', return_value={'state': 'down', 'foreign': False}), \
                patch.object(live, 'route', return_value={'interface': 'test-interface'}), \
                patch.object(live, 'ZONE', Path('/nonexistent-ocbar-selftest-resolver')), \
                patch.object(live, 'run', side_effect=fake_run), \
                patch.object(live.socket, 'socket') as fake_socket, \
                patch.object(live.getpass, 'getpass', side_effect=['synthetic-user', 'synthetic-password']):
            fake_socket.return_value.__enter__.return_value.getsockname.return_value = ('127.0.0.1', 9990)
            with self.assertRaises(StopBeforeConnection):
                live.main()
        self.assertNotEqual(captured['OCBAR_CONFIG_DIR'], source['OCBAR_CONFIG_DIR'])
        self.assertEqual(captured['OCBAR_TEST_PASSWORD'], 'synthetic-password')
        self.assertEqual(captured['PATH'], source['PATH'])
        return captured, source

    def test_default_connection_has_no_inherited_upstream_proxy(self):
        actual, source = self.connect_environment()
        for key in source:
            if key.lower().endswith('_proxy'):
                self.assertNotIn(key, actual, key + ' leaked into the VPN process')

    def test_explicit_upstream_is_written_to_profile(self):
        actual, _ = self.connect_environment(['--upstream-proxy', 'http://127.0.0.1:10808'])
        self.assertIn('UpstreamProxy = http://127.0.0.1:10808\n', actual['profile_text'])
        self.assertNotIn('https_proxy', actual)

    def test_explicit_proxy_comparison_preserves_environment(self):
        actual, source = self.connect_environment(['--inherit-proxy-env'])
        for key in source:
            if key.lower().endswith('_proxy'):
                self.assertEqual(actual[key], source[key])


if __name__ == '__main__':
    unittest.main()
