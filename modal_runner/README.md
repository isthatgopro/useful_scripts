# General Python runner for Modal

Run a Python project on Modal with one command and download its outputs, logs and GPU samples. The runner uses a Modal Sandbox so your script does not need to import `modal`.

## Quick start

```bash
python -m venv .venv
. .venv/bin/activate
python -m pip install -r modal_runner/requirements.txt
modal setup
python modal_runner/run.py modal_runner/example/modal-job.json --dry-run
python modal_runner/run.py modal_runner/example/modal-job.json
```

For another project, copy `example/modal-job.json` into that project, set `script` and `project_dir`, then run `python /path/to/useful_scripts/modal_runner/run.py /path/to/project/modal-job.json`. Paths in the JSON are relative to the JSON file (`project_dir`), while `script`, `image.requirements`, and `image.dockerfile` are relative to `project_dir`. Extra arguments can be passed after `--`:

```bash
python modal_runner/run.py project/modal-job.json --gpu H100 -- --epochs 10
```

Your Python script should write results into `os.environ["MODAL_RUN_OUTPUT_DIR"]` (`/results` remotely). Use `{output_dir}` in configured arguments to pass that path to an existing CLI script, for example `"args": ["--output", "{output_dir}/predictions.csv"]`. Anything else written outside `/results` is ephemeral unless explicitly placed in a mounted Volume. The runner streams timestamped stdout and stderr to the terminal and `runs/<run-id>/console.log`. It downloads `/results` into `runs/<run-id>/results`, including `job.json` and `gpu_samples.jsonl`, and writes `summary.json` plus `plan.json` locally. Outputs are recovered on a failed job when the Sandbox remains accessible.

## Environment and resources

Use `image.requirements` for your project's pip requirements, `image.pip_packages` for quick additions, and `image.apt_packages` for operating system dependencies. Alternatively set `image.dockerfile` to a Dockerfile inside the project. In that case its build context is the project directory; the image must provide Python and `tar`. A custom `image.registry` can replace the default Debian slim base. Dependencies are built before project source is mounted, so code edits usually reuse dependency layers. For GPU packages, specify compatible versions or a CUDA base image in the Dockerfile.

`gpu` accepts a Modal GPU specification such as `L4`, `A100`, or `H100:2`; use `null` for CPU only. `cpu` is in cores, `memory_mib` in MiB, `timeout_seconds` is the workload limit. Set `secrets` to names of existing Modal Secrets, `env` to non-sensitive environment variables, and `volumes` to an object mapping remote absolute mount paths to existing Modal Volume names (for example `{"/data": "my-data"}`). Upload only the small project code and inputs: the default ignore rules exclude `.git`, `.venv`, `.env`, `runs`, `outputs`, and Python caches; `ignore` adds Dockerignore-style patterns. Put large datasets and checkpoints on a Volume.

## Accounting and limits

`job.json` records observed GPU model, per-device sample count, mean/maximum utilization, and peak memory. Sampling comes from `nvidia-smi`, is periodic, and can miss short peaks. `summary.json` records requested GPU and Sandbox wall time. For an **optional rough GPU-only upper bound**, set `billing.gpu_usd_per_hour` to the current Modal price **per GPU** from `modal billing rates`; multiple GPU specifications multiply the rate. This excludes CPU, RAM, image builds, storage, and other charges. `billing_before.json` and `billing_after.json` are optional workspace-wide `modal billing summary --json` snapshots, which may lag and include other jobs. `credits_debited_exact` is always `null`: Modal does not expose a reliable per-run credit deduction on all plans. Exact granular billing reports require Team or Enterprise and are still before credits. See [Modal billing](https://modal.com/docs/guide/billing) and [CLI rates](https://modal.com/docs/cli/latest/billing).

The local Python environment only needs the Modal SDK. Run `modal setup` or supply Modal's usual token environment variables. `--dry-run` validates paths and prints the plan without starting compute. No GPU job is launched by this repository's tests.
