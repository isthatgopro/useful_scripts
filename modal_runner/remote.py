"""Execute one configured command inside a Modal Sandbox and record GPU samples."""

import argparse
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sample_gpu(samples, stop, interval):
    query = [
        "nvidia-smi", "--query-gpu=index,name,utilization.gpu,memory.used,memory.total",
        "--format=csv,noheader,nounits",
    ]
    while not stop.is_set():
        try:
            result = subprocess.run(query, capture_output=True, text=True, timeout=10, check=True)
            for row in csv.reader(result.stdout.splitlines()):
                if len(row) >= 5:
                    samples.append({
                        "time_utc": utc_now(), "index": int(row[0].strip()),
                        "name": row[1].strip(), "utilization_percent": float(row[2].strip()),
                        "memory_used_mib": float(row[3].strip()),
                        "memory_total_mib": float(row[4].strip()),
                    })
        except (FileNotFoundError, subprocess.SubprocessError, ValueError):
            pass  # CPU jobs and images without nvidia-smi have no GPU samples.
        stop.wait(interval)


def main():
    parser = argparse.ArgumentParser()
    entry = parser.add_mutually_exclusive_group(required=True)
    entry.add_argument("--script")  # Legacy shortcut.
    entry.add_argument("--command-json")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--workdir", default="/work")
    parser.add_argument("--sample-seconds", type=float, default=5)
    args, remainder = parser.parse_known_args()
    script_args = remainder[1:] if remainder and remainder[0] == "--" else remainder
    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    command = json.loads(args.command_json) if args.command_json else [sys.executable, "-u", args.script]
    if not isinstance(command, list) or not command or any(not isinstance(part, str) for part in command):
        parser.error("command must be a nonempty JSON array of strings")
    command.extend(script_args)
    started = time.monotonic()
    samples = []
    stop = threading.Event()
    thread = threading.Thread(target=sample_gpu, args=(samples, stop, args.sample_seconds), daemon=True)
    thread.start()
    exit_code = 1
    start_utc = utc_now()
    try:
        with subprocess.Popen(command, cwd=args.workdir, env={**os.environ, "MODAL_RUN_OUTPUT_DIR": str(output)},
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              bufsize=1) as process:
            for line in process.stdout:
                print(f"[{utc_now()}] {line}", end="", flush=True)
            exit_code = process.wait()
    finally:
        stop.set()
        thread.join(timeout=12)
        devices = {}
        for sample in samples:
            device = devices.setdefault(str(sample["index"]), {
                "name": sample["name"], "samples": 0, "peak_memory_mib": 0,
                "max_utilization_percent": 0, "utilization_total": 0,
            })
            device["samples"] += 1
            device["peak_memory_mib"] = max(device["peak_memory_mib"], sample["memory_used_mib"])
            device["max_utilization_percent"] = max(device["max_utilization_percent"], sample["utilization_percent"])
            device["utilization_total"] += sample["utilization_percent"]
        for device in devices.values():
            device["mean_utilization_percent"] = round(device.pop("utilization_total") / device["samples"], 2)
        (output / "gpu_samples.jsonl").write_text(
            "".join(json.dumps(sample) + "\n" for sample in samples), encoding="utf-8"
        )
        (output / "job.json").write_text(json.dumps({
            "command": command, "started_utc": start_utc, "finished_utc": utc_now(),
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "exit_code": exit_code, "gpu_devices": devices,
            "gpu_samples_available": bool(samples),
        }, indent=2) + "\n", encoding="utf-8")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
