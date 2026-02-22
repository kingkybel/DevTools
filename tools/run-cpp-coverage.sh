#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASE_IMAGE="ubuntu:24.04"
COMPILER_FAMILY="g++"
COMPILER_VERSION=""
PORT="8080"
CMAKE_ROOT=""
BUILD_TYPE="Debug"
COVERAGE_TOOL="auto"

usage() {
    cat <<'USAGE'
Usage: run-cpp-coverage.sh --cmake-root <path> [options]

Required:
  -c, --cmake-root <path>         Path to CMake project root on host.

Optional:
  -o, --os <image>                Base image (default: ubuntu:24.04)
      --compiler <name>           Compiler family: g++|gcc|clang (default: g++)
  -v, --compiler-version <major>  Compiler major version (default: latest available)
  -p, --port <port>               Host/container port for coverage site (default: 8080)
      --build-type <type>         CMake build type (default: Debug)
      --coverage-tool <name>      Coverage backend: auto|gcovr|fastcov (default: auto)
  -h, --help                      Show help
USAGE
}

normalize_compiler_family() {
    local raw="$1"
    local lower
    lower="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
    case "${lower}" in
        gcc|g++)
            echo "g++"
            ;;
        clang|llvm)
            echo "clang"
            ;;
        *)
            echo ""
            ;;
    esac
}

sanitize_for_tag() {
    local raw="$1"
    local lowered
    lowered="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
    lowered="${lowered//g++/gxx}"
    lowered="${lowered//clang++/clangxx}"
    lowered="$(printf '%s' "${lowered}" | tr '/:@ ' '-' | tr -cd 'a-z0-9_.-')"
    lowered="$(printf '%s' "${lowered}" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
    echo "${lowered}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--cmake-root)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --cmake-root/-c" >&2; exit 2; }
                CMAKE_ROOT="$1"
                shift
                ;;
            -o|--os|--base-image)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --os/-o" >&2; exit 2; }
                BASE_IMAGE="$1"
                shift
                ;;
            --compiler)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --compiler" >&2; exit 2; }
                local normalized
                normalized="$(normalize_compiler_family "$1")"
                [[ -n "${normalized}" ]] || { echo "Unsupported compiler '$1' (use g++|gcc|clang)" >&2; exit 2; }
                COMPILER_FAMILY="${normalized}"
                shift
                ;;
            -v|--compiler-version)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --compiler-version/-v" >&2; exit 2; }
                [[ "$1" =~ ^[0-9]+$ ]] || { echo "Compiler version must be numeric" >&2; exit 2; }
                COMPILER_VERSION="$1"
                shift
                ;;
            -p|--port)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --port/-p" >&2; exit 2; }
                [[ "$1" =~ ^[0-9]+$ ]] || { echo "Port must be numeric" >&2; exit 2; }
                PORT="$1"
                shift
                ;;
            --build-type)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --build-type" >&2; exit 2; }
                BUILD_TYPE="$1"
                shift
                ;;
            --coverage-tool)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --coverage-tool" >&2; exit 2; }
                case "$1" in
                    auto|gcovr|fastcov)
                        COVERAGE_TOOL="$1"
                        ;;
                    *)
                        echo "Unsupported coverage tool '$1' (use auto|gcovr|fastcov)" >&2
                        exit 2
                        ;;
                esac
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    [[ -n "${CMAKE_ROOT}" ]] || { echo "--cmake-root/-c is required" >&2; usage >&2; exit 2; }
    [[ -d "${CMAKE_ROOT}" ]] || { echo "CMake root '${CMAKE_ROOT}' does not exist" >&2; exit 2; }
    [[ -f "${CMAKE_ROOT}/CMakeLists.txt" ]] || { echo "No CMakeLists.txt found at '${CMAKE_ROOT}'" >&2; exit 2; }
}

parse_args "$@"

host_cmake_root="$(cd "${CMAKE_ROOT}" && pwd)"
base_tag="$(sanitize_for_tag "${BASE_IMAGE}")"
compiler_tag="$(sanitize_for_tag "${COMPILER_FAMILY}")"
version_tag="$(sanitize_for_tag "${COMPILER_VERSION}")"
[[ -n "${version_tag}" ]] || version_tag="latest"

IMAGE_TAG="cpp-coverage:${base_tag}-${compiler_tag}-${version_tag}"

echo "Building image ${IMAGE_TAG}"
docker build \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --build-arg COMPILER_FAMILY="${COMPILER_FAMILY}" \
    --build-arg COMPILER_VERSION="${COMPILER_VERSION}" \
    -f "${REPO_ROOT}/docker/cpp-coverage/Dockerfile" \
    -t "${IMAGE_TAG}" \
    "${REPO_ROOT}"

echo "Running coverage container on http://localhost:${PORT}"
DOCKER_TTY_ARGS=(-i)
if [[ -t 0 && -t 1 ]]; then
    DOCKER_TTY_ARGS=(-it)
fi

docker run --rm "${DOCKER_TTY_ARGS[@]}" \
    -p "${PORT}:${PORT}" \
    -e CMAKE_ROOT="${host_cmake_root}" \
    -e PORT="${PORT}" \
    -e COMPILER_FAMILY="${COMPILER_FAMILY}" \
    -e COMPILER_VERSION="${COMPILER_VERSION}" \
    -e BUILD_TYPE="${BUILD_TYPE}" \
    -e COVERAGE_TOOL="${COVERAGE_TOOL}" \
    -v "${host_cmake_root}:${host_cmake_root}" \
    "${IMAGE_TAG}"
