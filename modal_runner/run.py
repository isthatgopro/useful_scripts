"""Submit a configured local Python project to Modal and download its results."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import time
import uuid


ROOT = Path(__file__).resolve().parent
DEFAULT_IGNORE = [".git", ".venv", "__pycache__", "*.pyc", ".env", ".env.*", "runs", "outputs"]


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def within_project(project, value, must_exist=True):
    path = (project / value).resolve()
    if not path.is_relative_to(project):
        raise ValueError(f"Path must stay inside project_dir: {value}")
    if must_exist and not path.is_file():
        raise ValueError(f"File does not exist: {path}")
    return path


def load_config(config_path):
    config_path = config_path.resolve()
    cfg = json.loads(config_path.read_text(encoding="utf-8"))
    project = (config_path.parent / cfg.get("project_dir", ".")).resolve()
    if not project.is_dir():
        raise ValueError(f"Missing project_dir: {project}")
    script = within_project(project, cfg["script"])
    image_cfg = cfg.get("image", {})
    for field in ("requirements", "dockerfile"):
        if image_cfg.get(field):
            within_project(project, image_cfg[field])
    gpu = cfg.get("gpu")
    if gpu is not None and not isinstance(gpu, str):
        raise ValueError("gpu must be a Modal GPU specification or null")
    for key in ("args", "secrets", "ignore"):
        if not isinstance(cfg.get(key, []), list):
            raise ValueError(f"{key} must be a list")
    if any(not isinstance(arg, str) for arg in cfg.get("args", [])):
        raise ValueError("args must contain strings")
    if any(not isinstance(name, str) for name in cfg.get("secrets", [])):
        raise ValueError("secrets must contain Modal Secret names")
    if not isinstance(cfg.get("env", {}), dict) or not isinstance(cfg.get("volumes", {}), dict):
        raise ValueError("env and volumes must be objects")
    if any(not mount.startswith("/") for mount in cfg.get("volumes", {})):
        raise ValueError("Volume mount paths must be absolute")
    rate = cfg.get("billing", {}).get("gpu_usd_per_hour")
    if rate is not None and (isinstance(rate, bool) or not isinstance(rate, (float, int)) or rate < 0):
        raise ValueError("billing.gpu_usd_per_hour must be a nonnegative number or null")
    if cfg.get("timeout_seconds", 3600) < 60 or cfg.get("sample_seconds", 5) <= 0:
        raise ValueError("timeout_seconds must be >=60 and sample_seconds must be >0")
    return cfg, project, script


def build_image(modal, cfg, project):
    settings = cfg.get("image", {})
    if settings.get("dockerfile"):
        image = modal.Image.from_dockerfile(
            str(within_project(project, settings["dockerfile"])), context_dir=str(project)
        )
    elif settings.get("registry"):
        image = modal.Image.from_registry(settings["registry"])
    else:
        image = modal.Image.debian_slim(python_version=settings.get("python", "3.11"))
    if settings.get("apt_packages"):
        image = image.apt_install(*settings["apt_packages"])
    if settings.get("requirements"):
        image = image.pip_install_from_requirements(str(within_project(project, settings["requirements"])))
    if settings.get("pip_packages"):
        image = image.pip_install(*settings["pip_packages"])
    # Source code is added last to avoid rebuilding dependency layers on code edits.
    image = image.add_local_dir(str(project), "/work", ignore=DEFAULT_IGNORE + cfg.get("ignore", []))
    return image.add_local_file(str(ROOT / "remote.py"), "/opt/modal-runner/remote.py")


def billing_snapshot(run_dir, label):
    """Workspace-wide, delayed accounting snapshot; not a per-run charge."""
    try:
        result = subprocess.run(["modal", "billing", "summary", "--json"],
                                capture_output=True, text=True, timeout=35, check=False)
        (run_dir / f"billing_{label}.json").write_text(result.stdout if result.returncode == 0 else
            json.dumps({"unavailable": result.stderr.strip() or f"exit {result.returncode}"}), encoding="utf-8")
    except (OSError, subprocess.TimeoutExpired) as exc:
        (run_dir / f"billing_{label}.json").write_text(json.dumps({"unavailable": str(exc)}), encoding="utf-8")


def extract_results(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
                raise ValueError(f"Unsafe result archive entry: {member.name}")
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, target.open("wb") as sink:
                    while chunk := source.read(1024 * 1024):
                        sink.write(chunk)


def run(config_path, dry_run=False, gpu_override=None, extra_args=()):
    cfg, project, script = load_config(config_path)
    gpu = gpu_override if gpu_override is not None else cfg.get("gpu")
    script_args = [str(arg).replace("{output_dir}", "/results") for arg in cfg.get("args", [])]
    script_args.extend(extra_args)
    plan = {"project_dir": str(project), "script": str(script), "args": script_args,
            "gpu": gpu, "cpu": cfg.get("cpu", 2), "memory_mib": cfg.get("memory_mib", 8192),
            "timeout_seconds": cfg.get("timeout_seconds", 3600), "image": cfg.get("image", {})}
    if dry_run:
        print(json.dumps(plan, indent=2))
        return 0

    try:
        import modal
    except ImportError as exc:
        raise RuntimeError("Install the local Modal SDK: python -m pip install 'modal>=1.6,<2'") from exc

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    root = (config_path.resolve().parent / cfg.get("result_dir", "runs")).resolve()
    run_dir = root / run_id
    run_dir.mkdir(parents=True)
    (run_dir / "plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    if cfg.get("billing_snapshot", True):
        billing_snapshot(run_dir, "before")
    app = modal.App.lookup(cfg.get("app_name", "general-python-runner"), create_if_missing=True)
    image = build_image(modal, cfg, project)
    secrets = [modal.Secret.from_name(name) for name in cfg.get("secrets", [])]
    volumes = {mount: modal.Volume.from_name(name) for mount, name in cfg.get("volumes", {}).items()}
    started = time.monotonic()
    started_utc = utc_now()
    sandbox = None
    exit_code = None
    error = None
    try:
        print(f"Run {run_id}: starting Modal Sandbox; results: {run_dir}", flush=True)
        sandbox = modal.Sandbox.create(
            "sleep", "infinity", app=app, image=image, gpu=gpu,
            cpu=cfg.get("cpu", 2), memory=cfg.get("memory_mib", 8192),
            timeout=cfg.get("timeout_seconds", 3600) + 120,
            workdir="/work", secrets=secrets, volumes=volumes,
            env={"PYTHONUNBUFFERED": "1", **cfg.get("env", {})},
            tags={"run_id": run_id},
        )
        print(f"Sandbox ID: {sandbox.object_id}", flush=True)
        process = sandbox.exec(
            "python", "-u", "/opt/modal-runner/remote.py", "--script",
            "/work/" + str(script.relative_to(project)), "--output-dir", "/results",
            "--sample-seconds", str(cfg.get("sample_seconds", 5)), "--", *script_args,
            pty=True, timeout=cfg.get("timeout_seconds", 3600) + 30,
        )
        with (run_dir / "console.log").open("w", encoding="utf-8") as log:
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
                log.flush()
        exit_code = process.wait()
    except (Exception, KeyboardInterrupt) as exc:
        error = repr(exc)
        print(f"Run error: {error}", file=sys.stderr)
    finally:
        if sandbox is not None:
            try:
                # Copy even when the job failed: checkpoints and partial artifacts matter.
                packed = sandbox.exec("tar", "-czf", "/tmp/modal-run-results.tar.gz", "-C", "/results", ".")
                if packed.wait() == 0:
                    archive = run_dir / "results.tar.gz"
                    sandbox.filesystem.copy_to_local("/tmp/modal-run-results.tar.gz", str(archive))
                    extract_results(archive, run_dir / "results")
                else:
                    print("Could not pack remote results", file=sys.stderr)
            except Exception as exc:
                print(f"Could not download results: {exc}", file=sys.stderr)
                error = error or f"result download: {exc!r}"
            finally:
                try:
                    sandbox.terminate(wait=True)
                except Exception as exc:
                    print(f"Could not confirm Sandbox termination: {exc}", file=sys.stderr)
                    error = error or f"sandbox termination: {exc!r}"
        if cfg.get("billing_snapshot", True):
            billing_snapshot(run_dir, "after")
        elapsed = round(time.monotonic() - started, 3)
        rate = cfg.get("billing", {}).get("gpu_usd_per_hour")
        gpu_count = int(gpu.rsplit(":", 1)[1]) if gpu and ":" in gpu and gpu.rsplit(":", 1)[1].isdigit() else 1
        summary = {"run_id": run_id, "started_utc": started_utc, "finished_utc": utc_now(),
                   "sandbox_id": sandbox.object_id if sandbox else None, "gpu_requested": gpu,
                   "sandbox_elapsed_seconds": elapsed, "exit_code": exit_code, "error": error,
                   "estimated_gpu_usd_upper_bound": round(elapsed / 3600 * rate * gpu_count, 6) if gpu and rate else None,
                   "gpu_rate_usd_per_hour_configured": rate, "credits_debited_exact": None,
                   "billing_note": "GPU estimate uses sandbox wall time and a user supplied rate. CPU, memory, image builds and other charges are excluded. Billing snapshots are workspace-wide, delayed, and cannot establish this run's credit debit."}
        (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(summary, indent=2), flush=True)
        print(f"Results: {run_dir}", flush=True)
    return exit_code if exit_code is not None and error is None else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--gpu", help="Override configured Modal GPU, e.g. L4 or H100")
    parser.add_argument("--dry-run", action="store_true")
    args, extras = parser.parse_known_args()
    if extras and extras[0] == "--":
        extras = extras[1:]
    elif extras:
        parser.error("Pass extra script arguments after --")
    try:
        return run(args.config, args.dry_run, args.gpu, extras)
    except (ValueError, KeyError, OSError, RuntimeError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    sys.exit(main())
