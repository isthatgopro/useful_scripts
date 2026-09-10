#!/usr/bin/env bash

# Manage user-owned Docker CLI helpers without sudo. This script does not
# install, restart, or reconfigure the shared Docker Engine daemon.

set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
COMPOSE_PLUGIN_DIR="${COMPOSE_PLUGIN_DIR:-$HOME/.docker/cli-plugins}"
COMPOSE_PLUGIN_PATH="${COMPOSE_PLUGIN_PATH:-$COMPOSE_PLUGIN_DIR/docker-compose}"
DEFAULT_COMPOSE_VERSION="${DEFAULT_COMPOSE_VERSION:-v5.5.0}"

usage() {
    cat <<EOF
Usage:
  $PROGRAM_NAME doctor
  $PROGRAM_NAME ports [HOST_PORT]
  $PROGRAM_NAME install-compose [VERSION]
  $PROGRAM_NAME verify-compose
  $PROGRAM_NAME validate PROJECT_DIRECTORY [COMPOSE_FILE] [ENV_FILE]
  $PROGRAM_NAME status PROJECT_DIRECTORY [COMPOSE_FILE] [ENV_FILE]

Examples:
  $PROGRAM_NAME doctor
  $PROGRAM_NAME ports
  $PROGRAM_NAME ports 15174
  $PROGRAM_NAME install-compose
  $PROGRAM_NAME install-compose v5.5.0
  $PROGRAM_NAME verify-compose
  $PROGRAM_NAME validate "$HOME/repurgenesis_website"
  $PROGRAM_NAME status "$HOME/repurgenesis_website"

Environment overrides:
  COMPOSE_PLUGIN_DIR       Docker CLI plugin directory
                           (default: ~/.docker/cli-plugins)
  COMPOSE_PLUGIN_PATH      Docker Compose plugin path
                           (default: ~/.docker/cli-plugins/docker-compose)
  DEFAULT_COMPOSE_VERSION  Compose version used when VERSION is omitted
                           (default: v5.5.0)

Notes:
  - No sudo, APT, Snap, or system-directory modification is used.
  - install-compose downloads an official Docker Compose release from GitHub,
    verifies its SHA-256 sidecar, and installs it for the current user only.
  - ports and status are read-only.
  - validate only renders and validates Compose configuration; it does not
    build images or create, start, stop, or remove containers.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -fL "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only -O "$destination" "$url"
    else
        die "Downloading Docker Compose requires curl or wget"
    fi
}

normalize_compose_version() {
    local version="${1:-$DEFAULT_COMPOSE_VERSION}"

    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || \
        die "Compose version must look like 5.5.0 or v5.5.0"
    printf 'v%s' "$version"
}

compose_release_architecture() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'x86_64'
            ;;
        aarch64|arm64)
            printf 'aarch64'
            ;;
        armv7l|armv7)
            printf 'armv7'
            ;;
        *)
            die "Unsupported architecture for this helper: $(uname -m)"
            ;;
    esac
}

docker_daemon_available() {
    docker info >/dev/null 2>&1
}

compose_available() {
    docker compose version >/dev/null 2>&1
}

doctor() {
    local path

    printf 'Operating system: '
    uname -srmo 2>/dev/null || uname -a
    printf 'Architecture: %s\n' "$(uname -m)"

    printf '\nDocker CLI\n'
    if command -v docker >/dev/null 2>&1; then
        printf '  Executable: %s\n' "$(command -v docker)"
        docker --version 2>/dev/null | sed 's/^/  /' || true

        if docker_daemon_available; then
            printf '  Daemon access: usable\n'
        else
            printf '  Daemon access: unavailable or permission denied\n'
        fi
    else
        printf '  Docker CLI: not installed\n'
    fi

    printf '\nDocker Compose\n'
    if command -v docker >/dev/null 2>&1 && compose_available; then
        docker compose version 2>/dev/null | sed 's/^/  /'
    else
        printf '  docker compose: unavailable\n'
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        printf '  Legacy executable: %s\n' "$(command -v docker-compose)"
        docker-compose version 2>/dev/null | head -n 2 | sed 's/^/  /' || true
    else
        printf '  Legacy docker-compose: unavailable\n'
    fi

    printf '\nCompose plugin locations\n'
    for path in \
        "$COMPOSE_PLUGIN_PATH" \
        "/usr/local/lib/docker/cli-plugins/docker-compose" \
        "/usr/local/libexec/docker/cli-plugins/docker-compose" \
        "/usr/lib/docker/cli-plugins/docker-compose" \
        "/usr/libexec/docker/cli-plugins/docker-compose"; do
        if [[ -e "$path" || -L "$path" ]]; then
            ls -l -- "$path" | sed 's/^/  /'
        fi
    done
}

install_compose() {
    local requested_version="${1:-}"
    local version architecture release_url
    local temporary_directory=""
    local downloaded_binary checksum_file expected_checksum actual_checksum
    local backup_directory backup_path="" timestamp staged_plugin

    need_command docker
    need_command awk
    need_command sha256sum
    need_command mktemp

    if compose_available && [[ -z "$requested_version" ]]; then
        printf 'Docker Compose is already available; no change was made.\n'
        docker compose version
        printf 'To install a specific version explicitly, run:\n'
        printf '  %q install-compose v5.5.0\n' "$0"
        return 0
    fi

    version="$(normalize_compose_version "${requested_version:-$DEFAULT_COMPOSE_VERSION}")"
    architecture="$(compose_release_architecture)"
    release_url="https://github.com/docker/compose/releases/download/${version}/docker-compose-linux-${architecture}"

    temporary_directory="$(mktemp -d)"
    downloaded_binary="$temporary_directory/docker-compose"
    checksum_file="$temporary_directory/docker-compose.sha256"
    trap 'rm -rf -- "${temporary_directory:-}"' EXIT

    printf 'Downloading Docker Compose %s for linux/%s\n' "$version" "$architecture"
    download_file "$release_url" "$downloaded_binary"
    download_file "${release_url}.sha256" "$checksum_file"

    expected_checksum="$(awk 'NR == 1 { print $1 }' "$checksum_file")"
    [[ "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]] || \
        die "The release checksum file is invalid"

    actual_checksum="$(sha256sum "$downloaded_binary" | awk '{ print $1 }')"
    [[ "$actual_checksum" == "$expected_checksum" ]] || \
        die "SHA-256 verification failed; the downloaded binary was not installed"
    printf 'SHA-256 verification: OK\n'

    mkdir -p "$COMPOSE_PLUGIN_DIR"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

    if [[ -e "$COMPOSE_PLUGIN_PATH" || -L "$COMPOSE_PLUGIN_PATH" ]]; then
        backup_directory="$COMPOSE_PLUGIN_DIR/backups"
        backup_path="$backup_directory/docker-compose.${timestamp}"
        mkdir -p "$backup_directory"
        cp -p -- "$COMPOSE_PLUGIN_PATH" "$backup_path"
        printf 'Existing plugin backed up to: %s\n' "$backup_path"
    fi

    staged_plugin="$COMPOSE_PLUGIN_PATH.new.$$"
    cp -- "$downloaded_binary" "$staged_plugin"
    chmod 700 "$staged_plugin"
    mv -f -- "$staged_plugin" "$COMPOSE_PLUGIN_PATH"
    printf '%s  %s\n' "$expected_checksum" "$COMPOSE_PLUGIN_PATH" \
        > "${COMPOSE_PLUGIN_PATH}.sha256"

    if ! compose_available; then
        if [[ -n "$backup_path" ]]; then
            cp -p -- "$backup_path" "$COMPOSE_PLUGIN_PATH"
            printf 'The previous plugin was restored from: %s\n' "$backup_path" >&2
        else
            mv -- "$COMPOSE_PLUGIN_PATH" "${COMPOSE_PLUGIN_PATH}.failed.${timestamp}"
        fi
        die "Docker did not recognize the newly installed Compose plugin"
    fi

    rm -rf -- "$temporary_directory"
    temporary_directory=""
    trap - EXIT

    printf '\nDocker Compose installed successfully for the current user:\n'
    printf '  %s\n' "$COMPOSE_PLUGIN_PATH"
    docker compose version
}

verify_compose() {
    local expected_checksum actual_checksum

    need_command docker
    need_command sha256sum

    compose_available || \
        die "docker compose is unavailable; run '$PROGRAM_NAME install-compose'"

    docker compose version

    if [[ -f "$COMPOSE_PLUGIN_PATH" && -f "${COMPOSE_PLUGIN_PATH}.sha256" ]]; then
        expected_checksum="$(awk 'NR == 1 { print $1 }' "${COMPOSE_PLUGIN_PATH}.sha256")"
        [[ "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]] || \
            die "Saved checksum metadata is invalid: ${COMPOSE_PLUGIN_PATH}.sha256"
        actual_checksum="$(sha256sum "$COMPOSE_PLUGIN_PATH" | awk '{ print $1 }')"
        [[ "$actual_checksum" == "$expected_checksum" ]] || \
            die "Installed Compose plugin failed SHA-256 verification"
        printf 'User plugin SHA-256 verification: OK\n'
    else
        printf 'Compose was discovered outside the managed user-plugin path.\n'
        printf 'No checksum managed by this script is available for it.\n'
    fi
}

list_ports() {
    local requested_port="${1:-}"
    local docker_matches="" host_matches=""

    need_command docker
    docker_daemon_available || \
        die "Docker daemon access is unavailable or permission denied"

    if [[ -z "$requested_port" ]]; then
        printf 'Running containers and Docker port mappings\n'
        docker ps --format \
            'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

        printf '\nHost TCP listeners\n'
        if command -v ss >/dev/null 2>&1; then
            ss -lntp
        else
            printf 'ss is unavailable; only Docker-published ports were checked.\n'
        fi
        return 0
    fi

    [[ "$requested_port" =~ ^[0-9]+$ ]] || \
        die "Host port must be an integer from 1 to 65535"
    (( requested_port >= 1 && requested_port <= 65535 )) || \
        die "Host port must be an integer from 1 to 65535"

    docker_matches="$(
        docker ps \
            --filter "publish=$requested_port" \
            --format '{{.Names}}\t{{.Ports}}'
    )"

    if command -v ss >/dev/null 2>&1; then
        host_matches="$(ss -H -lnt "sport = :$requested_port" 2>/dev/null || true)"
    fi

    printf 'Docker matches for host port %s\n' "$requested_port"
    if [[ -n "$docker_matches" ]]; then
        printf '%s\n' "$docker_matches"
    else
        printf '  none\n'
    fi

    printf '\nHost listener matches for port %s\n' "$requested_port"
    if ! command -v ss >/dev/null 2>&1; then
        printf '  not checked because ss is unavailable\n'
    elif [[ -n "$host_matches" ]]; then
        printf '%s\n' "$host_matches"
    else
        printf '  none\n'
    fi

    if [[ -z "$docker_matches" && -z "$host_matches" ]] && \
       command -v ss >/dev/null 2>&1; then
        printf '\nPort %s appears available. Check again immediately before startup.\n' \
            "$requested_port"
    else
        printf '\nPort %s is occupied or could not be fully verified.\n' \
            "$requested_port"
    fi
}

RESOLVED_PROJECT_DIRECTORY=""
RESOLVED_COMPOSE_FILE=""
RESOLVED_ENV_FILE=""

resolve_project_files() {
    local requested_directory="$1"
    local requested_compose_file="${2:-}"
    local requested_env_file="${3:-}"

    [[ -d "$requested_directory" ]] || \
        die "Project directory does not exist: $requested_directory"
    RESOLVED_PROJECT_DIRECTORY="$(cd "$requested_directory" && pwd -P)"

    if [[ -z "$requested_compose_file" ]]; then
        RESOLVED_COMPOSE_FILE="$RESOLVED_PROJECT_DIRECTORY/infra/compose.yaml"
    elif [[ "$requested_compose_file" == /* ]]; then
        RESOLVED_COMPOSE_FILE="$requested_compose_file"
    else
        RESOLVED_COMPOSE_FILE="$RESOLVED_PROJECT_DIRECTORY/$requested_compose_file"
    fi

    if [[ -z "$requested_env_file" ]]; then
        RESOLVED_ENV_FILE="$RESOLVED_PROJECT_DIRECTORY/infra/.env"
    elif [[ "$requested_env_file" == /* ]]; then
        RESOLVED_ENV_FILE="$requested_env_file"
    else
        RESOLVED_ENV_FILE="$RESOLVED_PROJECT_DIRECTORY/$requested_env_file"
    fi

    [[ -f "$RESOLVED_COMPOSE_FILE" ]] || \
        die "Compose file does not exist: $RESOLVED_COMPOSE_FILE"
    [[ -f "$RESOLVED_ENV_FILE" ]] || \
        die "Environment file does not exist: $RESOLVED_ENV_FILE"
}

validate_project() {
    local project_directory compose_file env_file

    need_command docker
    compose_available || \
        die "docker compose is unavailable; run '$PROGRAM_NAME install-compose'"

    resolve_project_files "$1" "${2:-}" "${3:-}"
    project_directory="$RESOLVED_PROJECT_DIRECTORY"
    compose_file="$RESOLVED_COMPOSE_FILE"
    env_file="$RESOLVED_ENV_FILE"

    printf 'Project:      %s\n' "$project_directory"
    printf 'Compose file: %s\n' "$compose_file"
    printf 'Environment:  %s\n' "$env_file"

    (
        cd "$project_directory"
        docker compose \
            --env-file "$env_file" \
            --file "$compose_file" \
            config --quiet
    )

    printf 'Compose configuration: valid\n'
    printf 'No image was built and no container was changed.\n'
}

project_status() {
    local project_directory compose_file env_file

    need_command docker
    docker_daemon_available || \
        die "Docker daemon access is unavailable or permission denied"
    compose_available || \
        die "docker compose is unavailable; run '$PROGRAM_NAME install-compose'"

    resolve_project_files "$1" "${2:-}" "${3:-}"
    project_directory="$RESOLVED_PROJECT_DIRECTORY"
    compose_file="$RESOLVED_COMPOSE_FILE"
    env_file="$RESOLVED_ENV_FILE"

    (
        cd "$project_directory"
        docker compose \
            --env-file "$env_file" \
            --file "$compose_file" \
            ps --all
    )
}

main() {
    local action="${1:-}"

    case "$action" in
        doctor)
            [[ $# -eq 1 ]] || { usage; exit 2; }
            doctor
            ;;
        ports)
            [[ $# -le 2 ]] || { usage; exit 2; }
            list_ports "${2:-}"
            ;;
        install-compose)
            [[ $# -le 2 ]] || { usage; exit 2; }
            install_compose "${2:-}"
            ;;
        verify-compose)
            [[ $# -eq 1 ]] || { usage; exit 2; }
            verify_compose
            ;;
        validate)
            [[ $# -ge 2 && $# -le 4 ]] || { usage; exit 2; }
            validate_project "$2" "${3:-}" "${4:-}"
            ;;
        status)
            [[ $# -ge 2 && $# -le 4 ]] || { usage; exit 2; }
            project_status "$2" "${3:-}" "${4:-}"
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
