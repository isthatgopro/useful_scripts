"""Fast local checks; no Modal account or GPU required."""

import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

import run


class RunnerTests(unittest.TestCase):
    def test_dry_run_and_path_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "job.py").write_text("print('ok')\n")
            config = root / "config.json"
            config.write_text(json.dumps({"script": "job.py", "gpu": None}))
            self.assertEqual(run.run(config, dry_run=True), 0)
            config.write_text(json.dumps({"script": "../outside.py"}))
            with self.assertRaises(ValueError):
                run.load_config(config)

    def test_remote_results_and_failed_exit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "fail.py"
            script.write_text("import os, pathlib, sys\npathlib.Path(os.environ['MODAL_RUN_OUTPUT_DIR'], 'partial.txt').write_text('saved')\nprint('failure')\nsys.exit(7)\n")
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("remote.py")),
                "--script", str(script), "--workdir", str(root), "--output-dir", str(root / "results"),
                "--sample-seconds", "0.1"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 7)
            self.assertIn("failure", result.stdout)
            self.assertEqual((root / "results" / "partial.txt").read_text(), "saved")
            self.assertEqual(json.loads((root / "results" / "job.json").read_text())["exit_code"], 7)

    def test_reject_archive_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "bad.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                member = tarfile.TarInfo("escape")
                member.type = tarfile.SYMTYPE
                member.linkname = "../../outside"
                tar.addfile(member)
            with self.assertRaises(ValueError):
                run.extract_results(archive, root / "results")


if __name__ == "__main__":
    unittest.main()
