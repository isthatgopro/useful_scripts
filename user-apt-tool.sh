#!/usr/bin/env bash

# Install simple Debian/Ubuntu command-line packages into the current user's
# home directory without sudo. This does not modify the system package database.

set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
USER_APT_ROOT="${USER_APT_ROOT:-$HOME/.local/apt-user}"
USER_BIN_DIR="${USER_BIN_DIR:-$HOME/.local/bin}"
DEB_CACHE_DIR="$USER_APT_ROOT/debs"
PACKAGE_ROOT="$USER_APT_ROOT/packages"

usage() {
    cat <<EOF
Usage:
  $PROGRAM_NAME check PACKAGE [COMMAND]
  $PROGRAM_NAME cached [TEXT]
  $PROGRAM_NAME installed [TEXT]
  $PROGRAM_NAME install PACKAGE [COMMAND]
  $PROGRAM_NAME setup-path [SHELL_RC]

Examples:
  $PROGRAM_NAME check cmake
  $PROGRAM_NAME cached cmake
  $PROGRAM_NAME installed cmake
  $PROGRAM_NAME install tree
  $PROGRAM_NAME setup-path

Environment overrides:
  USER_APT_ROOT   Package/cache root (default: ~/.local/apt-user)
  USER_BIN_DIR    Command symlink directory (default: ~/.local/bin)

Notes:
  - No sudo is used.
  - "cached" means a .deb file exists; it does not mean it is installed.
  - This is intended for small command-line tools such as tree.
  - Packages with additional runtime/data dependencies may need those
    dependencies installed separately or an official portable distribution.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

package_field() {
    local deb_file="$1"
    local field="$2"
    dpkg-deb --field "$deb_file" "$field" 2>/dev/null || true
}

candidate_directories() {
    printf '%s\n' \
        "$DEB_CACHE_DIR" \
        "$PWD" \
        "$HOME/Downloads" \
        "/var/cache/apt/archives"
}

list_cached_debs() {
    local filter="${1:-}"
    local directory deb_file package version architecture
    local found=0

    need_command dpkg-deb

    while IFS= read -r directory; do
        [[ -d "$directory" ]] || continue

        while IFS= read -r -d '' deb_file; do
            package="$(package_field "$deb_file" Package)"
            version="$(package_field "$deb_file" Version)"
            architecture="$(package_field "$deb_file" Architecture)"

            [[ -n "$package" ]] || continue
            if [[ -n "$filter" && "${package,,} ${version,,} ${deb_file,,}" != *"${filter,,}"* ]]; then
                continue
            fi

            printf '%-28s %-22s %-10s %s\n' \
                "$package" "$version" "$architecture" "$deb_file"
            found=1
        done < <(find "$directory" -maxdepth 1 -type f -name '*.deb' -print0 2>/dev/null)
    done < <(candidate_directories)

    if (( found == 0 )); then
        printf 'No matching cached .deb files were found.\n'
    fi
}

list_installed_packages() {
    local filter="${1:-}"

    need_command dpkg-query

    dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null |
        awk -F '\t' -v needle="$filter" '
            BEGIN { IGNORECASE = 1 }
            needle == "" || index(tolower($1), tolower(needle)) > 0 {
                printf "%-36s %-24s %s\n", $1, $2, $3
            }
        '
}

check_package() {
    local package="$1"
    local command_name="${2:-$package}"
    local command_path=""

    printf 'Command check\n'
    if command_path="$(command -v "$command_name" 2>/dev/null)"; then
        printf '  %s is available at %s\n' "$command_name" "$command_path"
        "$command_path" --version 2>/dev/null | head -n 2 || true
    else
        printf '  %s is not currently on PATH.\n' "$command_name"
    fi

    printf '\nSystem package check\n'
    if dpkg-query -W -f='  ${binary:Package} ${Version} (${db:Status-Abbrev})\n' "$package" 2>/dev/null; then
        :
    else
        printf '  %s is not installed in the system package database.\n' "$package"
    fi

    if command -v apt-cache >/dev/null 2>&1; then
        printf '\nAPT candidate check\n'
        apt-cache policy "$package" 2>/dev/null | sed 's/^/  /' || true
    fi

    printf '\nCached .deb files\n'
    list_cached_debs "$package"
}

find_best_cached_deb() {
    local requested_package="$1"
    local native_arch
    local directory deb_file package version architecture
    local best_file=""
    local best_version=""

    native_arch="$(dpkg --print-architecture)"

    while IFS= read -r directory; do
        [[ -d "$directory" ]] || continue

        while IFS= read -r -d '' deb_file; do
            package="$(package_field "$deb_file" Package)"
            [[ "$package" == "$requested_package" ]] || continue

            architecture="$(package_field "$deb_file" Architecture)"
            [[ "$architecture" == "$native_arch" || "$architecture" == "all" ]] || continue

            version="$(package_field "$deb_file" Version)"
            if [[ -z "$best_file" ]] || dpkg --compare-versions "$version" gt "$best_version"; then
                best_file="$deb_file"
                best_version="$version"
            fi
        done < <(find "$directory" -maxdepth 1 -type f -name '*.deb' -print0 2>/dev/null)
    done < <(candidate_directories)

    printf '%s' "$best_file"
}

download_package() {
    local package="$1"

    need_command apt-get
    mkdir -p "$DEB_CACHE_DIR"

    printf 'No matching cached .deb found; downloading %s with APT...\n' "$package" >&2
    (
        cd "$DEB_CACHE_DIR"
        apt-get download "$package"
    )
}

find_executable() {
    local prefix="$1"
    local command_name="$2"
    local candidate

    for candidate in \
        "$prefix/usr/bin/$command_name" \
        "$prefix/bin/$command_name" \
        "$prefix/usr/sbin/$command_name" \
        "$prefix/sbin/$command_name"; do
        if [[ -f "$candidate" && -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

install_package() {
    local package="$1"
    local command_name="${2:-$package}"
    local existing_path deb_file version safe_version prefix stage executable link_path dependencies

    need_command apt-get
    need_command dpkg
    need_command dpkg-deb
    need_command find

    if existing_path="$(command -v "$command_name" 2>/dev/null)"; then
        printf '%s is already available at %s\n' "$command_name" "$existing_path"
        "$existing_path" --version 2>/dev/null | head -n 2 || true
        return 0
    fi

    mkdir -p "$DEB_CACHE_DIR" "$PACKAGE_ROOT" "$USER_BIN_DIR"

    deb_file="$(find_best_cached_deb "$package")"
    if [[ -z "$deb_file" ]]; then
        download_package "$package"
        deb_file="$(find_best_cached_deb "$package")"
    fi
    [[ -n "$deb_file" ]] || die "APT did not produce a usable .deb for $package"

    version="$(package_field "$deb_file" Version)"
    [[ -n "$version" ]] || die "Could not read package version from $deb_file"
    safe_version="${version//[^A-Za-z0-9._+-]/_}"
    prefix="$PACKAGE_ROOT/$package/$safe_version"

    dependencies="$(package_field "$deb_file" Depends)"
    printf 'Package:      %s\n' "$package"
    printf 'Version:      %s\n' "$version"
    printf 'Archive:      %s\n' "$deb_file"
    printf 'Dependencies: %s\n' "${dependencies:-none declared}"

    if [[ ! -d "$prefix" ]]; then
        stage="$(mktemp -d "$PACKAGE_ROOT/.${package}.stage.XXXXXX")"
        trap 'rm -rf -- "${stage:-}"' EXIT
        dpkg-deb --extract "$deb_file" "$stage"
        mkdir -p "$(dirname "$prefix")"
        mv "$stage" "$prefix"
        stage=""
        trap - EXIT
    else
        printf 'Reusing existing extracted package: %s\n' "$prefix"
    fi

    if ! executable="$(find_executable "$prefix" "$command_name")"; then
        printf 'Executables found in this package:\n' >&2
        find "$prefix" -type f -perm /111 -print 2>/dev/null | sed 's/^/  /' >&2 || true
        die "Command '$command_name' was not found. Retry with the command name as the second argument."
    fi

    link_path="$USER_BIN_DIR/$command_name"
    if [[ -e "$link_path" || -L "$link_path" ]]; then
        if [[ -L "$link_path" && "$(readlink -f "$link_path")" == "$(readlink -f "$executable")" ]]; then
            printf 'Command link already exists: %s\n' "$link_path"
        else
            die "Refusing to overwrite existing path: $link_path"
        fi
    else
        ln -s "$executable" "$link_path"
        printf 'Created command link: %s -> %s\n' "$link_path" "$executable"
    fi

    if command -v ldd >/dev/null 2>&1 && file "$executable" 2>/dev/null | grep -q 'dynamically linked'; then
        if ldd "$executable" 2>/dev/null | grep -q 'not found'; then
            printf '\nWARNING: shared libraries are missing:\n' >&2
            ldd "$executable" 2>/dev/null | grep 'not found' >&2 || true
        fi
    fi

    if [[ ":$PATH:" != *":$USER_BIN_DIR:"* ]]; then
        printf '\nAdd the user command directory to this shell with:\n'
        printf '  export PATH="%s:$PATH"\n' "$USER_BIN_DIR"
        printf 'Persist it with:\n'
        printf '  %q setup-path\n' "$0"
    else
        printf '\nInstalled successfully. Testing %s:\n' "$command_name"
        "$command_name" --version 2>/dev/null | head -n 2 || "$command_name" --help 2>/dev/null | head -n 2 || true
    fi
}

setup_path() {
    local shell_rc="${1:-$HOME/.bashrc}"
    local marker='# Added by user-apt-tool.sh'
    local path_line='export PATH="$HOME/.local/bin:$PATH"'

    mkdir -p "$USER_BIN_DIR"
    touch "$shell_rc"

    if grep -Fqx "$path_line" "$shell_rc"; then
        printf 'PATH entry already exists in %s\n' "$shell_rc"
    else
        {
            printf '\n%s\n' "$marker"
            printf '%s\n' "$path_line"
        } >> "$shell_rc"
        printf 'Added ~/.local/bin to PATH in %s\n' "$shell_rc"
    fi

    printf 'Run this now, or open a new terminal:\n'
    printf '  source %q\n' "$shell_rc"
}

main() {
    local action="${1:-}"

    case "$action" in
        check)
            [[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
            check_package "$2" "${3:-$2}"
            ;;
        cached)
            [[ $# -le 2 ]] || { usage; exit 2; }
            list_cached_debs "${2:-}"
            ;;
        installed)
            [[ $# -le 2 ]] || { usage; exit 2; }
            list_installed_packages "${2:-}"
            ;;
        install)
            [[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
            install_package "$2" "${3:-$2}"
            ;;
        setup-path)
            [[ $# -le 2 ]] || { usage; exit 2; }
            setup_path "${2:-$HOME/.bashrc}"
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
