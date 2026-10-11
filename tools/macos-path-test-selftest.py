#!/usr/bin/env python3
"""No-network checks of authentication trust across the diagnostic TCP relay."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('path_test', Path(__file__).with_name('macos-path-test.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class AuthenticationTrust(unittest.TestCase):
    def authenticate(self, port, output, returncode=0, error=''):
        result = subprocess.CompletedProcess([], returncode, output, error)
        with patch.object(probe.subprocess, 'run', return_value=result) as run, \
                patch.object(probe.shutil, 'which', return_value='/test/openconnect'):
            session = probe.authenticate('vpn.example.test', port, 'test-user', 'test-secret', {})
        return session, run.call_args.args[0]

    def test_relay_verifies_real_hostname_before_rewriting_endpoint(self):
        session, command = self.authenticate(12345,
            'part=one; second=two pin-sha256:synthetic https://vpn.example.test:12345/group\n')
        self.assertEqual(command[-1], 'https://vpn.example.test:12345')
        self.assertEqual(command[command.index('--resolve') + 1], 'vpn.example.test:127.0.0.1')
        self.assertIn('--no-proxy', command)
        self.assertNotIn('--servercert', command)  # Normal PKI at authentication.
        self.assertNotIn('--no-system-trust', command)
        self.assertEqual(session, ('part=one; second=two', 'pin-sha256:synthetic',
                                   'https://127.0.0.1:12345/group'))

    def test_direct_auth_keeps_real_endpoint(self):
        session, command = self.authenticate(None,
            'cookie pin-sha256:synthetic https://vpn.example.test/\n')
        self.assertNotIn('--resolve', command)
        self.assertEqual(session[2], 'https://vpn.example.test/')

    def test_unexpected_authentication_host_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'unexpected authentication redirect'):
            self.authenticate(12345, 'cookie pin-sha256:synthetic https://other.example.test/\n')

    def test_missing_verified_pin_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'verified server pin missing'):
            self.authenticate(12345, 'cookie unknown https://vpn.example.test:12345/\n')

    def test_auth_failure_does_not_expose_credentials(self):
        with self.assertRaises(RuntimeError) as error:
            self.authenticate(None, '', 1, 'test-user rejected test-secret')
        self.assertNotIn('test-user', str(error.exception))
        self.assertNotIn('test-secret', str(error.exception))


if __name__ == '__main__':
    unittest.main()
