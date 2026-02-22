#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PORT="8070"
TOOLS="cache,val,call"
EXECUTABLE=""
SOURCE_ROOT=""
WORKDIR_PATH=""
EXE_ARGS=()

usage() {
    cat <<'USAGE'
Usage: run-grind-analysis.sh --executable <path> [options] [-- <exe args...>]

Required:
  -e, --executable <path>          Executable to profile.

Optional:
  -t, --tools <list>               Comma-separated: cache,val,call (default: cache,val,call)
  -s, --source-root <path>         Source tree for clickable code links (default: executable dir)
  -w, --workdir <path>             Working directory when running executable (default: executable dir)
  -p, --port <port>                Report web port (default: 8070)
  -h, --help                       Show help

Examples:
  ./tools/run-grind-analysis.sh -e ../FixDecoder/build/Debug/bin/run_tests
  ./tools/run-grind-analysis.sh -e ./build/my_app -t cache,call -- --scenario perf
USAGE
}

normalize_tools() {
    local raw="$1"
    local token
    local out=()
    IFS=',' read -r -a arr <<< "${raw}"
    for token in "${arr[@]}"; do
        token="$(echo "${token}" | tr '[:upper:]' '[:lower:]' | xargs)"
        case "${token}" in
            cache|val|call)
                out+=("${token}")
                ;;
            "")
                ;;
            *)
                echo "Unsupported tool '${token}' (use cache,val,call)" >&2
                exit 2
                ;;
        esac
    done
    [[ ${#out[@]} -gt 0 ]] || { echo "No valid tools provided" >&2; exit 2; }
    (IFS=','; echo "${out[*]}")
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -e|--executable)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --executable/-e" >&2; exit 2; }
                EXECUTABLE="$1"
                shift
                ;;
            -t|--tools)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --tools/-t" >&2; exit 2; }
                TOOLS="$(normalize_tools "$1")"
                shift
                ;;
            -s|--source-root)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --source-root/-s" >&2; exit 2; }
                SOURCE_ROOT="$1"
                shift
                ;;
            -w|--workdir)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --workdir/-w" >&2; exit 2; }
                WORKDIR_PATH="$1"
                shift
                ;;
            -p|--port)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --port/-p" >&2; exit 2; }
                [[ "$1" =~ ^[0-9]+$ ]] || { echo "Port must be numeric" >&2; exit 2; }
                PORT="$1"
                shift
                ;;
            --)
                shift
                EXE_ARGS=("$@")
                break
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    [[ -n "${EXECUTABLE}" ]] || { echo "--executable/-e is required" >&2; usage >&2; exit 2; }
}

parse_args "$@"

exe_abs="$(cd "$(dirname "${EXECUTABLE}")" && pwd)/$(basename "${EXECUTABLE}")"
[[ -x "${exe_abs}" ]] || { echo "Executable not found or not executable: ${exe_abs}" >&2; exit 2; }

default_dir="$(pwd)"
if [[ -z "${SOURCE_ROOT}" ]]; then
    SOURCE_ROOT="${default_dir}"
fi
if [[ -z "${WORKDIR_PATH}" ]]; then
    WORKDIR_PATH="${default_dir}"
fi

source_abs="$(cd "${SOURCE_ROOT}" && pwd)"
workdir_abs="$(cd "${WORKDIR_PATH}" && pwd)"

[[ -d "${source_abs}" ]] || { echo "Source root not found: ${source_abs}" >&2; exit 2; }
[[ -d "${workdir_abs}" ]] || { echo "Workdir not found: ${workdir_abs}" >&2; exit 2; }

echo "Building image cpp-grind-web:latest"
docker build -f "${REPO_ROOT}/docker/cpp-grind-web/Dockerfile" -t cpp-grind-web:latest "${REPO_ROOT}"

DOCKER_TTY_ARGS=(-i)
if [[ -t 0 && -t 1 ]]; then
    DOCKER_TTY_ARGS=(-it)
fi

echo "Running grind analysis on ${exe_abs}"
echo "Web report will be available at http://localhost:${PORT}/index.html"

docker run --rm "${DOCKER_TTY_ARGS[@]}" \
  -p "${PORT}:${PORT}" \
  -e EXE_PATH="${exe_abs}" \
  -e SOURCE_ROOT="${source_abs}" \
  -e EXEC_WORKDIR="${workdir_abs}" \
  -e TOOLS="${TOOLS}" \
  -e PORT="${PORT}" \
  -e EXE_ARGS="${EXE_ARGS[*]-}" \
  -v "${source_abs}:${source_abs}" \
  -v "${workdir_abs}:${workdir_abs}" \
  -v "${exe_abs}:${exe_abs}:ro" \
  cpp-grind-web:latest
