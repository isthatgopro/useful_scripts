#!/usr/bin/env bash

# Shell entrypoint: reuse the repo's uv and Docker helpers, then invoke the
# small Modal SDK adapter. Docker checks are optional because Modal builds
# Dockerfile images remotely.

set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "$HERE/.." && pwd -P)"
UV_TOOL="$REPO/uv-env-tool.sh"
DOCKER_TOOL="$REPO/docker-user-tool.sh"
ENV_DIR="${MODAL_RUN_ENV_DIR:-$HOME/.cache/useful_scripts/modal_runner}"

usage() {
    cat <<'EOF'
Usage:
  modal-run.sh [OPTIONS] CONFIG.json [-- WORKLOAD_ARGUMENTS...]
  modal-run.sh --setup-only
  modal-run.sh --login

Options:
  --setup-only             Prepare the local uv environment and exit
  --login                  Prepare the environment and run modal setup
  --skip-setup             Use MODAL_RUN_PYTHON (default: python3) instead of uv
  --docker-doctor          Run docker-user-tool.sh doctor before the job
  --verify-compose        Run docker-user-tool.sh verify-compose before the job
  --compose-project DIR    Validate this project's Compose configuration
  --compose-file FILE      Compose path (relative to DIR, default infra/compose.yaml)
  --compose-env FILE       Env path (relative to DIR, default infra/.env)
  -h, --help               Show this help

All unrecognized options after CONFIG.json are forwarded to run.py.
Use '--' before extra workload arguments.

Examples:
  bash modal_runner/modal-run.sh project/modal-job.json
  bash modal_runner/modal-run.sh project/modal-job.json --gpu H100 -- --epochs 10
  bash modal_runner/modal-run.sh --docker-doctor --compose-project project project/modal-job.json

Local setup calls the existing uv-env-tool.sh. Docker options call the
existing docker-user-tool.sh. A local Docker daemon is not required for
Modal's remote Dockerfile image build.
EOF
}

setup_only=0
login=0
skip_setup=0
docker_doctor=0
verify_compose=0
compose_project=""
compose_file=""
compose_env=""
declare -a forwarded=()

while (($#)); do
    case "$1" in
        --setup-only) setup_only=1; shift ;;
        --login) login=1; shift ;;
        --skip-setup) skip_setup=1; shift ;;
        --docker-doctor) docker_doctor=1; shift ;;
        --verify-compose) verify_compose=1; shift ;;
        --compose-project|--compose-file|--compose-env)
            (($# >= 2)) || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
            case "$1" in
                --compose-project) compose_project="$2" ;;
                --compose-file) compose_file="$2" ;;
                --compose-env) compose_env="$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) forwarded+=("$1"); shift ;;
    esac
done

if (( (setup_only || login) && skip_setup )) || ((setup_only && login)); then
    printf '%s\n' '--login, --setup-only and --skip-setup are mutually exclusive' >&2
    exit 2
fi
if [[ -z "$compose_project" && ( -n "$compose_file" || -n "$compose_env" ) ]]; then
    printf '%s\n' '--compose-file and --compose-env require --compose-project' >&2
    exit 2
fi
for argument in "${forwarded[@]}"; do
    if [[ "$argument" == "--dry-run" && $setup_only -eq 0 && $login -eq 0 ]]; then
        skip_setup=1
    fi
done

if ((docker_doctor || verify_compose)) || [[ -n "$compose_project" ]]; then
    [[ -f "$DOCKER_TOOL" ]] || { printf 'Missing %s\n' "$DOCKER_TOOL" >&2; exit 2; }
    if ((docker_doctor)); then bash "$DOCKER_TOOL" doctor; fi
    if ((verify_compose)); then bash "$DOCKER_TOOL" verify-compose; fi
    if [[ -n "$compose_project" ]]; then
        bash "$DOCKER_TOOL" validate "$compose_project" "${compose_file:-infra/compose.yaml}" "${compose_env:-infra/.env}"
    fi
fi

if ((!skip_setup)); then
    [[ -f "$UV_TOOL" ]] || { printf 'Missing %s\n' "$UV_TOOL" >&2; exit 2; }
    bash "$UV_TOOL" bootstrap
    bash "$UV_TOOL" create "$ENV_DIR" "${MODAL_RUN_PYTHON_VERSION:-3.11}"
    bash "$UV_TOOL" install-file "$ENV_DIR" "$HERE/requirements.txt"
fi

if ((setup_only)); then
    printf 'Modal local environment is ready.\n'
    exit 0
fi
if ((login)); then
    exec bash "$UV_TOOL" run "$ENV_DIR" modal setup
fi

((${#forwarded[@]})) || { usage >&2; exit 2; }
if ((skip_setup)); then
    exec "${MODAL_RUN_PYTHON:-python3}" "$HERE/run.py" "${forwarded[@]}"
else
    exec bash "$UV_TOOL" run "$ENV_DIR" python "$HERE/run.py" "${forwarded[@]}"
fi
