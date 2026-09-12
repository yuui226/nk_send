"""Keep the Windows handoff progress documents internally consistent."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROGRESS = ROOT / "docs/技术调研/iOS剩余任务进度表.md"
EXTENSIONS = ROOT / "docs/技术调研/iOS扩展功能任务表.md"


class ProgressLedgerTest(unittest.TestCase):
    def test_current_group_count_matches_detail_rows(self):
        text = PROGRESS.read_text(encoding="utf-8")
        self.assertIn("7 组 Windows 侧源码/账本修正完成、2 组未完成", text)
        rows = re.findall(r"^\| C(\d\d) [^|]*\| ([^|]+) \|", text, re.M)
        self.assertEqual([int(number) for number, _ in rows], list(range(1, 10)))
        unfinished = [number for number, state in rows if "未完成" in state]
        self.assertEqual(unfinished, ["07", "08"])

    def test_extension_table_does_not_count_partial_work_as_done(self):
        text = EXTENSIONS.read_text(encoding="utf-8")
        self.assertIn("当前仍为 0/34，0%", text)
        for prefix, count in (("E", 12), ("G", 8), ("R", 10), ("X", 4)):
            rows = re.findall(r"^\| (" + prefix + r"\d\d?) \|[^|]*\|[^|]*\| ([^|]+) \|", text, re.M)
            self.assertEqual(len(rows), count)
            self.assertTrue(all(state.strip().startswith(("TODO", "DOING")) for _, state in rows))


if __name__ == "__main__":
    unittest.main()
