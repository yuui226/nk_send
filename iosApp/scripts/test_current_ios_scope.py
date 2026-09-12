"""Regression coverage for the current-branch handoff gate."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_current_ios_scope import verify


class CurrentIOSScopeTest(unittest.TestCase):
    def test_android_scope_and_ios_effect_owner_are_current(self):
        verify()


if __name__ == "__main__":
    unittest.main()
