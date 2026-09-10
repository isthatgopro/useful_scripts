#!/usr/bin/env bash

# Manage user-owned uv installations and Python virtual environments without
# sudo. This script is intentionally application-neutral: Docling, data tools,
# web projects, and other Python workloads can each use their own directory.

set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
UV_BIN_DIR="${UV_BIN_DIR:-$HOME/.local/bin}"
UV_ENV_NAME="${UV_ENV_NAME:-.venv}"

usage() {
    cat <<EOF
Usage:
  $PROGRAM_NAME bootstrap [VERSION|latest]
  $PROGRAM_NAME setup-path [SHELL_RC]
  $PROGRAM_NAME doctor
  $PROGRAM_NAME create DIRECTORY [PYTHON_VERSION]
  $PROGRAM_NAME install DIRECTORY PACKAGE [PACKAGE ...]
  $PROGRAM_NAME install-file DIRECTORY REQUIREMENTS_FILE
  $PROGRAM_NAME uninstall DIRECTORY PACKAGE [PACKAGE ...]
  $PROGRAM_NAME torch DIRECTORY [BACKEND] [PACKAGE ...]
  $PROGRAM_NAME list DIRECTORY
  $PROGRAM_NAME freeze DIRECTORY
  $PROGRAM_NAME info DIRECTORY
  $PROGRAM_NAME activate DIRECTORY
  $PROGRAM_NAME run DIRECTORY COMMAND [ARGUMENT ...]
  $PROGRAM_NAME tool-install PACKAGE
  $PROGRAM_NAME tool-list

Examples:
  $PROGRAM_NAME bootstrap
  $PROGRAM_NAME create "$HOME/work/docling_gpu" 3.12
  $PROGRAM_NAME torch "$HOME/work/docling_gpu" auto
  $PROGRAM_NAME install "$HOME/work/docling_gpu" docling pandas xlsxwriter pillow
  $PROGRAM_NAME install-file "$HOME/work/analysis" requirements.txt
  $PROGRAM_NAME run "$HOME/work/docling_gpu" python docling_poc_gpu.py --help
  $PROGRAM_NAME freeze "$HOME/work/docling_gpu" > requirements.lock.txt

Environment overrides:
  UV_BIN_DIR    uv installation directory (default: ~/.local/bin)
  UV_BIN        explicit uv executable path
  UV_ENV_NAME   environment directory name (default: .venv)

Notes:
  - No sudo or system-Python modification is used.
  - create reuses a valid existing environment and refuses to replace a broken
    or unrelated environment directory.
  - torch passes BACKEND to uv. Common values include auto, cpu, cu126,
    cu128, and cu130; uv performs the authoritative validation.
  - activate prints the command because a child script cannot modify the
    calling shell's environment.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

find_uv() {
    if [[ -n "${UV_BIN:-}" ]]; then
        [[ -x "$UV_BIN" ]] || return 1
        printf '%s' "$UV_BIN"
    elif command -v uv >/dev/null 2>&1; then
        command -v uv
    elif [[ -x "$UV_BIN_DIR/uv" ]]; then
        printf '%s' "$UV_BIN_DIR/uv"
    else
        return 1
    fi
}

require_uv() {
    local uv_path=""

    if ! uv_path="$(find_uv)"; then
        die "uv is not installed; run '$PROGRAM_NAME bootstrap' first"
    fi

    printf '%s' "$uv_path"
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only -qO "$destination" "$url"
    else
        die "Downloading uv requires curl or wget"
    fi
}

bootstrap_uv() {
    local requested_version="${1:-}"
    local version="${requested_version:-latest}"
    local installer_url
    local temporary_directory=""
    local installer_path
    local uv_path=""

    if uv_path="$(find_uv)" && [[ -z "$requested_version" ]]; then
        printf 'uv is already installed at %s\n' "$uv_path"
        "$uv_path" --version
        return 0
    fi

    if [[ "$version" == "latest" ]]; then
        installer_url="https://astral.sh/uv/install.sh"
    else
        version="${version#v}"
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
            die "uv version must look like 0.12.7, v0.12.7, or latest"
        installer_url="https://astral.sh/uv/$version/install.sh"
    fi

    mkdir -p "$UV_BIN_DIR"
    temporary_directory="$(mktemp -d)"
    installer_path="$temporary_directory/uv-install.sh"
    trap 'rm -rf -- "${temporary_directory:-}"' EXIT

    printf 'Downloading the official uv installer from %s\n' "$installer_url"
    download_file "$installer_url" "$installer_path"
    [[ -s "$installer_path" ]] || die "The downloaded uv installer is empty"

    UV_INSTALL_DIR="$UV_BIN_DIR" \
    UV_NO_MODIFY_PATH=1 \
        sh "$installer_path"

    rm -rf -- "$temporary_directory"
    temporary_directory=""
    trap - EXIT

    uv_path="$UV_BIN_DIR/uv"
    [[ -x "$uv_path" ]] || die "uv installer finished but $uv_path was not created"

    printf '\nuv installed successfully:\n'
    "$uv_path" --version

    if [[ ":$PATH:" != *":$UV_BIN_DIR:"* ]]; then
        printf '\nAdd it to this shell with:\n'
        printf '  export PATH="%s:$PATH"\n' "$UV_BIN_DIR"
        printf 'Persist it with:\n'
        printf '  %q setup-path\n' "$0"
    fi
}

setup_path() {
    local shell_rc="${1:-$HOME/.bashrc}"
    local marker='# Added by uv-env-tool.sh'
    local path_line

    if [[ "$UV_BIN_DIR" == "$HOME/.local/bin" ]]; then
        path_line='export PATH="$HOME/.local/bin:$PATH"'
    else
        path_line="export PATH=\"$UV_BIN_DIR:\$PATH\""
    fi

    mkdir -p "$UV_BIN_DIR"
    touch "$shell_rc"

    if grep -Fqx "$path_line" "$shell_rc"; then
        printf 'PATH entry already exists in %s\n' "$shell_rc"
    else
        {
            printf '\n%s\n' "$marker"
            printf '%s\n' "$path_line"
        } >> "$shell_rc"
        printf 'Added the uv binary directory to PATH in %s\n' "$shell_rc"
    fi

    printf 'Run this now, or open a new terminal:\n'
    printf '  source %q\n' "$shell_rc"
}

resolve_directory() {
    local requested_directory="$1"

    mkdir -p "$requested_directory"
    (
        cd "$requested_directory"
        pwd -P
    )
}

resolve_existing_directory() {
    local requested_directory="$1"

    [[ -d "$requested_directory" ]] || \
        die "Directory does not exist: $requested_directory"
    (
        cd "$requested_directory"
        pwd -P
    )
}

environment_python() {
    local project_directory="$1"
    local python_path="$project_directory/$UV_ENV_NAME/bin/python"

    [[ -x "$python_path" ]] || \
        die "No valid environment at $project_directory/$UV_ENV_NAME; run create first"
    printf '%s' "$python_path"
}

environment_bin() {
    local project_directory="$1"
    printf '%s' "$project_directory/$UV_ENV_NAME/bin"
}

create_environment() {
    local requested_directory="$1"
    local python_version="${2:-3.12}"
    local project_directory
    local virtual_environment
    local python_path
    local uv_path

    uv_path="$(require_uv)"
    project_directory="$(resolve_directory "$requested_directory")"
    virtual_environment="$project_directory/$UV_ENV_NAME"
    python_path="$virtual_environment/bin/python"

    if [[ -x "$python_path" ]]; then
        printf 'Reusing existing environment: %s\n' "$virtual_environment"
    elif [[ -e "$virtual_environment" ]]; then
        die "Refusing to replace invalid existing path: $virtual_environment"
    else
        printf 'Creating Python %s environment: %s\n' \
            "$python_version" "$virtual_environment"
        "$uv_path" venv "$virtual_environment" --python "$python_version"
    fi

    "$python_path" -c \
        "import sys; print('Python:', sys.version.split()[0]); print('Executable:', sys.executable)"
    printf 'Activate with:\n'
    printf '  source %q\n' "$virtual_environment/bin/activate"
}

install_packages() {
    local requested_directory="$1"
    shift
    local project_directory python_path uv_path

    [[ $# -ge 1 ]] || die "install requires at least one package"
    uv_path="$(require_uv)"
    project_directory="$(resolve_existing_directory "$requested_directory")"
    python_path="$(environment_python "$project_directory")"

    "$uv_path" pip install --python "$python_path" "$@"
}

install_from_file() {
    local requested_directory="$1"
    local requirements_file="$2"
    local project_directory python_path uv_path

    [[ -f "$requirements_file" ]] || \
        die "Requirements file does not exist: $requirements_file"
    uv_path="$(require_uv)"
    project_directory="$(resolve_existing_directory "$requested_directory")"
    python_path="$(environment_python "$project_directory")"

    "$uv_path" pip install \
        --python "$python_path" \
        --requirement "$requirements_file"
}

uninstall_packages() {
    local requested_directory="$1"
    shift
    local project_directory python_path uv_path

    [[ $# -ge 1 ]] || die "uninstall requires at least one package"
    uv_path="$(require_uv)"
    project_directory="$(resolve_existing_directory "$requested_directory")"
    python_path="$(environment_python "$project_directory")"

    "$uv_path" pip uninstall --python "$python_path" "$@"
}

install_torch() {
    local requested_directory="$1"
    local backend="${2:-auto}"
    shift 2 || true
    local project_directory python_path uv_path
    local -a packages

    [[ "$backend" =~ ^[A-Za-z0-9._-]+$ && "$backend" != -* ]] || \
        die "Invalid PyTorch backend: $backend"

    if (( $# == 0 )); then
        packages=(torch torchvision)
    else
        packages=("$@")
    fi

    uv_path="$(require_uv)"
    if ! "$uv_path" pip install --help 2>/dev/null | grep -q -- '--torch-backend'; then
        die "This command requires a newer uv; run '$PROGRAM_NAME bootstrap latest'"
    fi

    project_directory="$(resolve_existing_directory "$requested_directory")"
    python_path="$(environment_python "$project_directory")"

    "$uv_path" pip install \
        --python "$python_path" \
        --torch-backend="$backend" \
        "${packages[@]}"
}

list_packages() {
    local project_directory python_path uv_path

    uv_path="$(require_uv)"
    project_directory="$(resolve_existing_directory "$1")"
    python_path="$(environment_python "$project_directory")"
    "$uv_path" pip list --python "$python_path"
}

freeze_packages() {
    local project_directory python_path uv_path

    uv_path="$(require_uv)"
    project_directory="$(resolve_existing_directory "$1")"
    python_path="$(environment_python "$project_directory")"
    "$uv_path" pip freeze --python "$python_path"
}

show_environment_info() {
    local project_directory python_path

    project_directory="$(resolve_existing_directory "$1")"
    python_path="$(environment_python "$project_directory")"

    printf 'Environment: %s/%s\n' "$project_directory" "$UV_ENV_NAME"
    "$python_path" -c \
        "import platform, sys; print('Python:', sys.version.split()[0]); print('Executable:', sys.executable); print('Platform:', platform.platform())"

    if "$python_path" -c 'import torch' >/dev/null 2>&1; then
        "$python_path" -c \
            "import torch; print('PyTorch:', torch.__version__); print('CUDA build:', torch.version.cuda); print('CUDA available:', torch.cuda.is_available()); print('GPU:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'None')"
    else
        printf 'PyTorch: not installed\n'
    fi
}

print_activation() {
    local project_directory

    project_directory="$(resolve_existing_directory "$1")"
    environment_python "$project_directory" >/dev/null
    printf 'source %q\n' "$project_directory/$UV_ENV_NAME/bin/activate"
}

run_in_environment() {
    local requested_directory="$1"
    shift
    local project_directory env_bin

    [[ $# -ge 1 ]] || die "run requires a command"
    project_directory="$(resolve_existing_directory "$requested_directory")"
    environment_python "$project_directory" >/dev/null
    env_bin="$(environment_bin "$project_directory")"

    (
        cd "$project_directory"
        PATH="$env_bin:$PATH" \
        VIRTUAL_ENV="$project_directory/$UV_ENV_NAME" \
            "$@"
    )
}

doctor() {
    local uv_path=""

    printf 'Operating system: '
    uname -srmo 2>/dev/null || uname -a
    printf 'Architecture: %s\n' "$(uname -m)"

    if uv_path="$(find_uv)"; then
        printf 'uv executable: %s\n' "$uv_path"
        "$uv_path" --version
        printf 'uv cache: %s\n' "$("$uv_path" cache dir 2>/dev/null || printf 'unavailable')"
        printf 'uv Python directory: %s\n' "$("$uv_path" python dir 2>/dev/null || printf 'unavailable')"
    else
        printf 'uv: not installed\n'
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        printf '\nNVIDIA GPU\n'
        nvidia-smi \
            --query-gpu=index,name,memory.total,driver_version \
            --format=csv,noheader 2>/dev/null || nvidia-smi
    else
        printf '\nNVIDIA GPU: nvidia-smi is not available\n'
    fi

    printf '\nHome-directory storage\n'
    df -h "$HOME" | tail -n 1
}

install_tool() {
    local uv_path

    uv_path="$(require_uv)"
    "$uv_path" tool install "$1"
}

list_tools() {
    local uv_path

    uv_path="$(require_uv)"
    "$uv_path" tool list
}

main() {
    local action="${1:-}"

    case "$action" in
        bootstrap)
            [[ $# -le 2 ]] || { usage; exit 2; }
            bootstrap_uv "${2:-}"
            ;;
        setup-path)
            [[ $# -le 2 ]] || { usage; exit 2; }
            setup_path "${2:-$HOME/.bashrc}"
            ;;
        doctor)
            [[ $# -eq 1 ]] || { usage; exit 2; }
            doctor
            ;;
        create)
            [[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
            create_environment "$2" "${3:-3.12}"
            ;;
        install)
            [[ $# -ge 3 ]] || { usage; exit 2; }
            install_packages "$2" "${@:3}"
            ;;
        install-file)
            [[ $# -eq 3 ]] || { usage; exit 2; }
            install_from_file "$2" "$3"
            ;;
        uninstall)
            [[ $# -ge 3 ]] || { usage; exit 2; }
            uninstall_packages "$2" "${@:3}"
            ;;
        torch)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            install_torch "$2" "${3:-auto}" "${@:4}"
            ;;
        list)
            [[ $# -eq 2 ]] || { usage; exit 2; }
            list_packages "$2"
            ;;
        freeze)
            [[ $# -eq 2 ]] || { usage; exit 2; }
            freeze_packages "$2"
            ;;
        info)
            [[ $# -eq 2 ]] || { usage; exit 2; }
            show_environment_info "$2"
            ;;
        activate)
            [[ $# -eq 2 ]] || { usage; exit 2; }
            print_activation "$2"
            ;;
        run)
            [[ $# -ge 3 ]] || { usage; exit 2; }
            run_in_environment "$2" "${@:3}"
            ;;
        tool-install)
            [[ $# -eq 2 ]] || { usage; exit 2; }
            install_tool "$2"
            ;;
        tool-list)
            [[ $# -eq 1 ]] || { usage; exit 2; }
            list_tools
            ;;
        -h|--help|help|'')
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
