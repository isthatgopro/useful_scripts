# General command runner for Modal

Run a Python project, training command or other CLI task on Modal and download its outputs, logs and GPU samples. The public entrypoint is a shell script. A small Python adapter uses the Modal SDK locally, and a remote helper executes your configured command; your workload does not need to import `modal`.

## Quick start

```bash
# First time only: prepare a local uv environment and authenticate with Modal.
bash modal_runner/modal-run.sh --login

# Dry run needs no Modal SDK and starts no cloud compute.
bash modal_runner/modal-run.sh modal_runner/example/modal-job.json --dry-run

# One command: uv-env-tool.sh prepares a cached local environment, then runs the job.
bash modal_runner/modal-run.sh modal_runner/example/modal-job.json
```

For another project, copy `example/modal-job.json` into that project, set `command` and `project_dir`, then run `bash /path/to/useful_scripts/modal_runner/modal-run.sh /path/to/project/modal-job.json`. `project_dir` is relative to the JSON file; `image.requirements` and `image.dockerfile` are relative to `project_dir`. Commands run with `/work` as the remote working directory. For a simple Python script, you can set `"script": "train.py"` and `"args": ["--epochs", "10"]` instead of `command`. Extra workload arguments can be passed after `--`:

```bash
bash modal_runner/modal-run.sh project/modal-job.json --gpu H100 -- --epochs 10
```

For maximum flexibility, use a command array, for example `"command": ["python", "-u", "train.py", "--output", "{output_dir}/model.pt"]` or `"command": ["bash", "-lc", "python prepare.py && python train.py"]`. The shell form is explicit and intended for trusted project commands. Both `{output_dir}` and `{project_dir}` are expanded to `/results` and `/work` inside the Sandbox. A Dockerfile may provide any required CLI tools, but must also provide `python` and `tar` for the runner.

Set `model_name` to a short label if you run several models. It is saved alongside the command and resource usage in `plan.json` and `summary.json`. A run containing several model commands is measured as a whole; run them separately if you need per-model GPU attribution.

## Reusing the other tools

The shell entrypoint calls `uv-env-tool.sh bootstrap`, `create`, `install-file`, then `run`. It caches the environment under `~/.cache/useful_scripts/modal_runner` by default. `MODAL_RUN_ENV_DIR` and `MODAL_RUN_PYTHON_VERSION` override the location and Python version. Run `bash modal_runner/modal-run.sh --setup-only` to prepare it in advance. If you already have a Python environment with the Modal SDK, use `--skip-setup` (with `MODAL_RUN_PYTHON=/path/to/python` when needed).

Docker checks use the existing `docker-user-tool.sh`:

```bash
bash modal_runner/modal-run.sh --docker-doctor project/modal-job.json
bash modal_runner/modal-run.sh --verify-compose --compose-project project project/modal-job.json
bash modal_runner/modal-run.sh --compose-project project --compose-file infra/compose.yaml --compose-env infra/.env project/modal-job.json
```

These options are local preflight checks. `--compose-project` invokes `docker-user-tool.sh validate`, which requires a Compose file and env file; `--verify-compose` checks the installed plugin. Docker checks are optional because Modal builds `image.dockerfile` remotely without a local Docker daemon. The Docker helper does not build your image.

Your script should write results into `os.environ["MODAL_RUN_OUTPUT_DIR"]` (`/results` remotely). Use `{output_dir}` in configured command arguments to pass that path to an existing CLI script. Anything else written outside `/results` is ephemeral unless explicitly placed in a mounted Volume. The runner streams timestamped workload stdout and stderr to the terminal and `runs/<run-id>/console.log`. Modal's image build and object creation progress is shown on the terminal. It downloads `/results` into `runs/<run-id>/results`, including `job.json` and `gpu_samples.jsonl`, and writes `summary.json` plus `plan.json` locally. Outputs are recovered on a failed job when the Sandbox remains accessible.

## Environment and resources

Use `image.requirements` for your project's pip requirements, `image.pip_packages` for quick additions, and `image.apt_packages` for operating system dependencies. Alternatively set `image.dockerfile` to a Dockerfile inside the project. In that case its build context is the project directory; the image must provide Python and `tar`. A custom `image.registry` can replace the default Debian slim base. Dependencies are built before project source is mounted, so code edits usually reuse dependency layers. For GPU packages, specify compatible versions or a CUDA base image in the Dockerfile.

`gpu` accepts a Modal GPU specification such as `L4`, `A100`, or `H100:2`; use `null` for CPU only. `cpu` is in cores, `memory_mib` in MiB, `timeout_seconds` is the workload limit. Set `secrets` to names of existing Modal Secrets, `env` to non-sensitive environment variables, and `volumes` to an object mapping remote absolute mount paths to existing Modal Volume names (for example `{"/data": "my-data"}`). Upload only the small project code and inputs: the default ignore rules exclude `.git`, `.venv`, `.env`, `runs`, `outputs`, and Python caches; `ignore` adds Dockerignore-style patterns. Put large datasets and checkpoints on a Volume.

## Accounting and limits

`job.json` records observed GPU model, per-device sample count, mean/maximum utilization, and peak memory. Sampling comes from `nvidia-smi`, is periodic, and can miss short peaks. `summary.json` records requested GPU and Sandbox wall time. For an **optional rough GPU-only upper bound**, set `billing.gpu_usd_per_hour` to the current Modal price **per GPU** from `modal billing rates`; multiple GPU specifications multiply the rate. This excludes CPU, RAM, image builds, storage, and other charges. `billing_before.json` and `billing_after.json` are optional workspace-wide `modal billing summary --json` snapshots, which may lag and include other jobs. `credits_debited_exact` is always `null`: Modal does not expose a reliable per-run credit deduction on all plans. Exact granular billing reports require Team or Enterprise and are still before credits. See [Modal billing](https://modal.com/docs/guide/billing) and [CLI rates](https://modal.com/docs/cli/latest/billing).

The local Python environment only needs the Modal SDK. Run `modal setup` or supply Modal's usual token environment variables. `--dry-run` validates paths and prints the plan without installing packages or starting compute. No GPU job is launched by this repository's tests.
