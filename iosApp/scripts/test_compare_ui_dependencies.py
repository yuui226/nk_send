import unittest
from compare_ui_dependencies import modules, differences


class DependencyDiffTest(unittest.TestCase):
    def test_reports_upgrades_additions_and_removals(self):
        before = modules("a:b:1\nx:y:2\nu:v:3\n")
        after = modules("a:b:2\nx:y:2\nn:m:1\n")
        self.assertEqual(differences(before, after), [("a:b", "1", "2"), ("n:m", None, "1"), ("u:v", "3", None)])

    def test_duplicate_versions_are_not_silently_accepted(self):
        with self.assertRaises(ValueError):
            modules("a:b:1\na:b:2")

    def test_sort_and_line_endings_do_not_invent_changes(self):
        self.assertEqual(differences(modules("c:d:2\r\na:b:1\r\n"), modules("a:b:1\nc:d:2\n")), [])
