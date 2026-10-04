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

            config.write_text(json.dumps({"command": ["python", "-u", "job.py", "--out", "{output_dir}/x"]}))
            cfg, project, command = run.load_config(config)
            self.assertEqual(command[:3], ["python", "-u", "job.py"])
            self.assertEqual(run.run(config, dry_run=True, extra_args=("--test",)), 0)

    def test_remote_results_and_failed_exit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "fail.py"
            script.write_text("import os, pathlib, sys\npathlib.Path(os.environ['MODAL_RUN_OUTPUT_DIR'], 'partial.txt').write_text('saved')\nprint('failure')\nsys.exit(7)\n")
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("remote.py")),
                "--command-json", json.dumps([sys.executable, str(script)]),
                "--workdir", str(root), "--output-dir", str(root / "results"),
                "--sample-seconds", "0.1"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 7)
            self.assertIn("failure", result.stdout)
            self.assertEqual((root / "results" / "partial.txt").read_text(), "saved")
            self.assertEqual(json.loads((root / "results" / "job.json").read_text())["exit_code"], 7)

    def test_shell_entrypoint_dry_run(self):
        repo = Path(__file__).resolve().parent.parent
        result = subprocess.run(["bash", str(repo / "modal_runner" / "modal-run.sh"),
            str(repo / "modal_runner" / "example" / "modal-job.json"), "--dry-run"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["command"], ["python", "-u", "job.py"])

    def test_shell_reuses_uv_helper(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "modal_runner").mkdir()
            source = Path(__file__).with_name("modal-run.sh")
            (root / "modal_runner" / "modal-run.sh").write_bytes(source.read_bytes())
            (root / "modal_runner" / "requirements.txt").write_text("modal>=1.6,<2\n")
            stub = root / "uv-env-tool.sh"
            stub.write_text("#!/bin/bash\nprintf '%s\\n' \"$1\" >> \"$ACTION_LOG\"\n")
            import os
            result = subprocess.run(["bash", str(root / "modal_runner" / "modal-run.sh"), "--setup-only"],
                env={**os.environ, "ACTION_LOG": str(root / "actions")}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "actions").read_text().splitlines(), ["bootstrap", "create", "install-file"])

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
