#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PORT="8060"
EXECUTABLE=""
SOURCE_ROOT=""
WORKDIR_PATH=""
PERF_FREQ="99"
EXE_ARGS=()

usage() {
    cat <<'USAGE'
Usage: run-cpp-profiler.sh --executable <path> [options] [-- <exe args...>]

Required:
  -e, --executable <path>          Executable to profile.

Optional:
  -s, --source-root <path>         Source tree for profiling context (default: current dir)
  -w, --workdir <path>             Working directory for executable (default: current dir)
  -p, --port <port>                Report web port (default: 8060)
  -f, --frequency <hz>             perf sample frequency (default: 99)
  -h, --help                       Show help

Examples:
  ./tools/run-cpp-profiler.sh -e ../FixDecoder/build/Debug/bin/run_tests
  ./tools/run-cpp-profiler.sh -e ./build/my_app -f 199 -- --scenario perf --size 1000
USAGE
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
            -f|--frequency)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --frequency/-f" >&2; exit 2; }
                [[ "$1" =~ ^[0-9]+$ ]] || { echo "Frequency must be numeric" >&2; exit 2; }
                PERF_FREQ="$1"
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
[[ -e "${exe_abs}" ]] || { echo "Executable not found: ${exe_abs}" >&2; exit 2; }
[[ -f "${exe_abs}" ]] || { echo "Executable path is not a file: ${exe_abs}" >&2; exit 2; }
[[ -x "${exe_abs}" ]] || { echo "Executable is not executable: ${exe_abs}" >&2; exit 2; }

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

echo "Building image cpp-profiler-web:latest"
docker build -f "${REPO_ROOT}/docker/cpp-profiler-web/Dockerfile" -t cpp-profiler-web:latest "${REPO_ROOT}"

DOCKER_TTY_ARGS=(-i)
if [[ -t 0 && -t 1 ]]; then
    DOCKER_TTY_ARGS=(-it)
fi

echo "Running CPU profiling on ${exe_abs}"
echo "Profiler dashboard will be available at http://localhost:${PORT}/index.html"

docker run --rm "${DOCKER_TTY_ARGS[@]}" \
  --cap-add SYS_ADMIN \
  --cap-add SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -p "${PORT}:${PORT}" \
  -e EXE_PATH="${exe_abs}" \
  -e SOURCE_ROOT="${source_abs}" \
  -e EXEC_WORKDIR="${workdir_abs}" \
  -e PERF_FREQ="${PERF_FREQ}" \
  -e PORT="${PORT}" \
  -e EXE_ARGS="${EXE_ARGS[*]-}" \
  -v "${source_abs}:${source_abs}" \
  -v "${workdir_abs}:${workdir_abs}" \
  -v "${exe_abs}:${exe_abs}:ro" \
  cpp-profiler-web:latest
