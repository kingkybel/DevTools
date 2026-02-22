#!/usr/bin/env bash
set -euo pipefail

SONAR_PORT="9000"
SOURCE_ROOT=""
PROJECT_KEY="devtools-local-project"
PROJECT_NAME="DevTools Local Project"
PROJECT_VERSION="1.0"
SONAR_IMAGE="sonarqube:community"
SCANNER_IMAGE="sonarsource/sonar-scanner-cli:latest"
SONAR_TOKEN="${SONAR_TOKEN:-}"
COMPILE_COMMANDS=""
WAIT_TIMEOUT="300"
START_ONLY=0
STOP_ONLY=0

usage() {
    cat <<'USAGE'
Usage: run-sonarqube-analysis.sh [options]

Description:
  Start (or reuse) a local SonarQube container, run analysis for a source tree,
  and show results on localhost.

Options:
  -s, --source-root <path>         Source root to scan.
  -p, --port <port>                SonarQube localhost port (default: 9000)
  -k, --project-key <key>          Sonar project key (default: devtools-local-project)
  -n, --project-name <name>        Sonar project name (default: DevTools Local Project)
      --project-version <version>  Project version string (default: 1.0)
      --sonar-token <token>        Sonar token (or set SONAR_TOKEN env var)
      --compile-commands <path>    compile_commands.json path (for C/C++ analyzer)
      --sonar-image <image>        SonarQube image (default: sonarqube:community)
      --scanner-image <image>      Scanner image (default: sonarsource/sonar-scanner-cli:latest)
      --wait-timeout <seconds>     Wait timeout for SonarQube startup (default: 300)
      --start-only                 Only start/wait for SonarQube, do not run scan
      --stop                       Stop and remove the SonarQube container for this port
  -h, --help                       Show help

Examples:
  ./tools/run-sonarqube-analysis.sh --source-root ../FixDecoder
  ./tools/run-sonarqube-analysis.sh --source-root ../FixDecoder --port 9010 --project-key fixdecoder
  ./tools/run-sonarqube-analysis.sh --stop --port 9000
USAGE
}

require_cmd() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo "Required command not found: ${cmd}" >&2
        exit 2
    }
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -s|--source-root)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --source-root/-s" >&2; exit 2; }
                SOURCE_ROOT="$1"
                shift
                ;;
            -p|--port)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --port/-p" >&2; exit 2; }
                [[ "$1" =~ ^[0-9]+$ ]] || { echo "Port must be numeric" >&2; exit 2; }
                SONAR_PORT="$1"
                shift
                ;;
            -k|--project-key)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --project-key/-k" >&2; exit 2; }
                PROJECT_KEY="$1"
                shift
                ;;
            -n|--project-name)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --project-name/-n" >&2; exit 2; }
                PROJECT_NAME="$1"
                shift
                ;;
            --project-version)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --project-version" >&2; exit 2; }
                PROJECT_VERSION="$1"
                shift
                ;;
            --sonar-token)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --sonar-token" >&2; exit 2; }
                SONAR_TOKEN="$1"
                shift
                ;;
            --compile-commands)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --compile-commands" >&2; exit 2; }
                COMPILE_COMMANDS="$1"
                shift
                ;;
            --sonar-image)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --sonar-image" >&2; exit 2; }
                SONAR_IMAGE="$1"
                shift
                ;;
            --scanner-image)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --scanner-image" >&2; exit 2; }
                SCANNER_IMAGE="$1"
                shift
                ;;
            --wait-timeout)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --wait-timeout" >&2; exit 2; }
                [[ "$1" =~ ^[0-9]+$ ]] || { echo "--wait-timeout must be numeric seconds" >&2; exit 2; }
                WAIT_TIMEOUT="$1"
                shift
                ;;
            --start-only)
                START_ONLY=1
                shift
                ;;
            --stop)
                STOP_ONLY=1
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    if [[ "${STOP_ONLY}" -eq 0 ]]; then
        [[ -n "${SOURCE_ROOT}" || "${START_ONLY}" -eq 1 ]] || {
            echo "--source-root/-s is required unless --start-only or --stop is used" >&2
            exit 2
        }
    fi
}

wait_for_sonarqube() {
    local timeout_secs="$1"
    local start_ts
    start_ts="$(date +%s)"

    echo "Waiting for SonarQube to become ready on http://localhost:${SONAR_PORT} ..."
    while true; do
        if curl -fsS "http://localhost:${SONAR_PORT}/api/system/status" 2>/dev/null | rg -q '"status":"UP"'; then
            echo "SonarQube is UP."
            return 0
        fi

        local now elapsed
        now="$(date +%s)"
        elapsed="$((now - start_ts))"
        if (( elapsed > timeout_secs )); then
            echo "Timed out waiting for SonarQube after ${timeout_secs}s" >&2
            echo "Check logs: docker logs ${CONTAINER_NAME}" >&2
            return 1
        fi
        sleep 2
    done
}

parse_args "$@"
require_cmd docker
require_cmd curl
require_cmd rg

CONTAINER_NAME="devtools-sonarqube-${SONAR_PORT}"

if [[ "${STOP_ONLY}" -eq 1 ]]; then
    if docker ps -a --format '{{.Names}}' | rg -xq "${CONTAINER_NAME}"; then
        echo "Stopping/removing ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null
    else
        echo "Container ${CONTAINER_NAME} not found."
    fi
    exit 0
fi

if docker ps --format '{{.Names}}' | rg -xq "${CONTAINER_NAME}"; then
    echo "Reusing running SonarQube container ${CONTAINER_NAME}"
elif docker ps -a --format '{{.Names}}' | rg -xq "${CONTAINER_NAME}"; then
    echo "Starting existing SonarQube container ${CONTAINER_NAME}"
    docker start "${CONTAINER_NAME}" >/dev/null
else
    echo "Starting SonarQube container ${CONTAINER_NAME} on port ${SONAR_PORT}"
    docker run -d \
        --name "${CONTAINER_NAME}" \
        -p "${SONAR_PORT}:9000" \
        -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
        -e SONAR_WEB_JAVAOPTS='-Xms256m -Xmx512m' \
        -e SONAR_CE_JAVAOPTS='-Xms256m -Xmx512m' \
        "${SONAR_IMAGE}" >/dev/null
fi

wait_for_sonarqube "${WAIT_TIMEOUT}"

if [[ "${START_ONLY}" -eq 1 ]]; then
    echo "SonarQube URL: http://localhost:${SONAR_PORT}"
    echo "Container name: ${CONTAINER_NAME}"
    exit 0
fi

host_source_root="$(cd "${SOURCE_ROOT}" && pwd)"
[[ -d "${host_source_root}" ]] || { echo "Source root '${SOURCE_ROOT}' does not exist" >&2; exit 2; }

scanner_args=(
    "-Dsonar.projectKey=${PROJECT_KEY}"
    "-Dsonar.projectName=${PROJECT_NAME}"
    "-Dsonar.projectVersion=${PROJECT_VERSION}"
    "-Dsonar.sources=."
)

if [[ -n "${SONAR_TOKEN}" ]]; then
    scanner_args+=("-Dsonar.token=${SONAR_TOKEN}")
fi

if [[ -n "${COMPILE_COMMANDS}" ]]; then
    compile_commands_abs="$(cd "$(dirname "${COMPILE_COMMANDS}")" && pwd)/$(basename "${COMPILE_COMMANDS}")"
    [[ -f "${compile_commands_abs}" ]] || { echo "compile_commands file not found: ${COMPILE_COMMANDS}" >&2; exit 2; }
    case "${compile_commands_abs}" in
        "${host_source_root}"/*)
            rel_compile="${compile_commands_abs#${host_source_root}/}"
            scanner_args+=("-Dsonar.cfamily.compile-commands=/usr/src/${rel_compile}")
            ;;
        *)
            echo "--compile-commands must be inside --source-root so it can be mounted into scanner container" >&2
            exit 2
            ;;
    esac
fi

echo "Running SonarQube scan for ${host_source_root}"
docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    -e SONAR_HOST_URL="http://host.docker.internal:${SONAR_PORT}" \
    -v "${host_source_root}:/usr/src" \
    -w /usr/src \
    "${SCANNER_IMAGE}" \
    "${scanner_args[@]}"

echo "SonarQube dashboard: http://localhost:${SONAR_PORT}/dashboard?id=${PROJECT_KEY}"
echo "SonarQube home:      http://localhost:${SONAR_PORT}"
