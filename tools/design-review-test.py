#!/usr/bin/env python3
"""Capture acceptance checks; never launch an app or a screenshot."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).with_name('design-review.py')
spec = importlib.util.spec_from_file_location('design_review', SCRIPT)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class CaptureAcceptance(unittest.TestCase):
    def setUp(self):
        self.passive = dict(capture='screencapture-passive-window', focusPreserved=True,
                            builtInDisplay=True, appearanceMode='inactive',
                            active=False, keyWindow=False, mainWindow=False)
        self.active = dict(capture='screencapture-window', active=True, keyWindow=True, mainWindow=True)

    def test_modes_cannot_be_confused(self):
        self.assertTrue(review.valid_capture(self.passive, True))
        self.assertTrue(review.valid_capture(self.active, False))
        self.assertFalse(review.valid_capture(self.active, True))
        self.assertFalse(review.valid_capture(self.passive, False))

    def test_passive_rejects_focus_or_wrong_display(self):
        for key in ('active', 'keyWindow', 'mainWindow'):
            with self.subTest(key=key):
                self.assertFalse(review.valid_capture(dict(self.passive, **{key: True}), True))
        for key in ('focusPreserved', 'builtInDisplay'):
            with self.subTest(key=key):
                self.assertFalse(review.valid_capture(dict(self.passive, **{key: False}), True))

    def test_missing_proof_is_rejected(self):
        for key in self.passive:
            report = self.passive.copy()
            del report[key]
            with self.subTest(key=key):
                self.assertFalse(review.valid_capture(report, True))

    def test_no_implicit_or_ambiguous_capture(self):
        for flags in ([], ['--capture-active', '--capture-passive'], ['--capture-passive', '--offscreen']):
            result = subprocess.run([sys.executable, str(SCRIPT), *flags], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
