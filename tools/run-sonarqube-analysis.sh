#!/usr/bin/env bash
set -euo pipefail

SONAR_PORT="9000"
SOURCE_ROOT=""
DEFAULT_PROJECT_KEY="devtools-local-project"
DEFAULT_PROJECT_NAME="DevTools Local Project"
DEFAULT_PROJECT_VERSION="1.0"
PROJECT_KEY=""
PROJECT_NAME=""
PROJECT_VERSION=""
PROJECT_KEY_EXPLICIT=0
PROJECT_NAME_EXPLICIT=0
PROJECT_VERSION_EXPLICIT=0
SONAR_IMAGE="sonarqube:community"
SCANNER_IMAGE="sonarsource/sonar-scanner-cli:latest"
SONAR_TOKEN="${SONAR_TOKEN:-}"
SONAR_LOGIN="${SONAR_LOGIN:-}"
SONAR_PASSWORD="${SONAR_PASSWORD:-}"
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
      --sonar-login <user>         Sonar login/user (or set SONAR_LOGIN env var)
      --sonar-password <pass>      Sonar password (or set SONAR_PASSWORD env var)
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
            --source-root=*)
                SOURCE_ROOT="${1#*=}"
                shift
                ;;
            -s|--source-root)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --source-root/-s" >&2; exit 2; }
                SOURCE_ROOT="$1"
                shift
                ;;
            --port=*)
                SONAR_PORT="${1#*=}"
                [[ "${SONAR_PORT}" =~ ^[0-9]+$ ]] || { echo "Port must be numeric" >&2; exit 2; }
                shift
                ;;
            -p|--port)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --port/-p" >&2; exit 2; }
                [[ "$1" =~ ^[0-9]+$ ]] || { echo "Port must be numeric" >&2; exit 2; }
                SONAR_PORT="$1"
                shift
                ;;
            --project-key=*)
                PROJECT_KEY="${1#*=}"
                PROJECT_KEY_EXPLICIT=1
                shift
                ;;
            -k|--project-key)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --project-key/-k" >&2; exit 2; }
                PROJECT_KEY="$1"
                PROJECT_KEY_EXPLICIT=1
                shift
                ;;
            --project-name=*)
                PROJECT_NAME="${1#*=}"
                PROJECT_NAME_EXPLICIT=1
                shift
                ;;
            -n|--project-name)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --project-name/-n" >&2; exit 2; }
                PROJECT_NAME="$1"
                PROJECT_NAME_EXPLICIT=1
                shift
                ;;
            --project-version=*)
                PROJECT_VERSION="${1#*=}"
                PROJECT_VERSION_EXPLICIT=1
                shift
                ;;
            --project-version)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --project-version" >&2; exit 2; }
                PROJECT_VERSION="$1"
                PROJECT_VERSION_EXPLICIT=1
                shift
                ;;
            --sonar-token=*)
                SONAR_TOKEN="${1#*=}"
                shift
                ;;
            --sonar-token)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --sonar-token" >&2; exit 2; }
                SONAR_TOKEN="$1"
                shift
                ;;
            --sonar-login=*)
                SONAR_LOGIN="${1#*=}"
                shift
                ;;
            --sonar-login)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --sonar-login" >&2; exit 2; }
                SONAR_LOGIN="$1"
                shift
                ;;
            --sonar-password=*)
                SONAR_PASSWORD="${1#*=}"
                shift
                ;;
            --sonar-password)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --sonar-password" >&2; exit 2; }
                SONAR_PASSWORD="$1"
                shift
                ;;
            --compile-commands=*)
                COMPILE_COMMANDS="${1#*=}"
                shift
                ;;
            --compile-commands)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --compile-commands" >&2; exit 2; }
                COMPILE_COMMANDS="$1"
                shift
                ;;
            --sonar-image=*)
                SONAR_IMAGE="${1#*=}"
                shift
                ;;
            --sonar-image)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --sonar-image" >&2; exit 2; }
                SONAR_IMAGE="$1"
                shift
                ;;
            --scanner-image=*)
                SCANNER_IMAGE="${1#*=}"
                shift
                ;;
            --scanner-image)
                shift
                [[ $# -gt 0 ]] || { echo "Missing value for --scanner-image" >&2; exit 2; }
                SCANNER_IMAGE="$1"
                shift
                ;;
            --wait-timeout=*)
                WAIT_TIMEOUT="${1#*=}"
                [[ "${WAIT_TIMEOUT}" =~ ^[0-9]+$ ]] || { echo "--wait-timeout must be numeric seconds" >&2; exit 2; }
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

has_project_props=0
if [[ -f "${host_source_root}/sonar-project.properties" ]]; then
    has_project_props=1
fi

resolved_project_key=""

# Optional convenience: load auth from files in source root if flags/env were not provided.
if [[ -z "${SONAR_TOKEN}" && -z "${SONAR_LOGIN}" && -z "${SONAR_PASSWORD}" ]]; then
    if [[ -f "${host_source_root}/sonar.token" ]]; then
        SONAR_TOKEN="$(tr -d '\r\n' < "${host_source_root}/sonar.token")"
    elif [[ -f "${host_source_root}/sonar.login" && -f "${host_source_root}/sonar.password" ]]; then
        SONAR_LOGIN="$(tr -d '\r\n' < "${host_source_root}/sonar.login")"
        SONAR_PASSWORD="$(tr -d '\r\n' < "${host_source_root}/sonar.password")"
    fi
fi

scanner_args=(
    "-Dsonar.sources=."
)

if [[ "${PROJECT_KEY_EXPLICIT}" -eq 1 ]]; then
    scanner_args+=("-Dsonar.projectKey=${PROJECT_KEY}")
    resolved_project_key="${PROJECT_KEY}"
elif [[ "${has_project_props}" -eq 0 ]]; then
    scanner_args+=("-Dsonar.projectKey=${DEFAULT_PROJECT_KEY}")
    resolved_project_key="${DEFAULT_PROJECT_KEY}"
else
    resolved_project_key="$(awk -F= '/^[[:space:]]*sonar\.projectKey[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "${host_source_root}/sonar-project.properties" || true)"
fi

if [[ "${PROJECT_NAME_EXPLICIT}" -eq 1 ]]; then
    scanner_args+=("-Dsonar.projectName=${PROJECT_NAME}")
elif [[ "${has_project_props}" -eq 0 ]]; then
    scanner_args+=("-Dsonar.projectName=${DEFAULT_PROJECT_NAME}")
fi

if [[ "${PROJECT_VERSION_EXPLICIT}" -eq 1 ]]; then
    scanner_args+=("-Dsonar.projectVersion=${PROJECT_VERSION}")
elif [[ "${has_project_props}" -eq 0 ]]; then
    scanner_args+=("-Dsonar.projectVersion=${DEFAULT_PROJECT_VERSION}")
fi

if [[ -n "${SONAR_TOKEN}" ]]; then
    # SonarQube 9.9 LTS expects token via sonar.login.
    scanner_args+=("-Dsonar.login=${SONAR_TOKEN}")
else
    # Local SonarQube instances commonly keep default admin/admin credentials.
    sonar_login="${SONAR_LOGIN:-admin}"
    sonar_password="${SONAR_PASSWORD:-admin}"
    scanner_args+=("-Dsonar.login=${sonar_login}" "-Dsonar.password=${sonar_password}")
    if [[ -z "${SONAR_LOGIN}" && -z "${SONAR_PASSWORD}" ]]; then
        echo "No token provided; trying SonarQube credentials admin/admin."
    fi
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

# Warn early when scanning C/C++ files on SonarQube instances without CFamily analyzer.
has_cpp_files=0
if rg --files "${host_source_root}" \
    -g '*.c' -g '*.cc' -g '*.cpp' -g '*.cxx' \
    -g '*.h' -g '*.hh' -g '*.hpp' -g '*.hxx' \
    | head -n 1 | rg -q .; then
    has_cpp_files=1
fi

if [[ "${has_cpp_files}" -eq 1 ]]; then
    cfamily_installed=0
    if [[ -n "${SONAR_TOKEN}" ]]; then
        if curl -fsS -u "${SONAR_TOKEN}:" "http://localhost:${SONAR_PORT}/api/plugins/installed" 2>/dev/null | rg -q '"key":"cfamily"'; then
            cfamily_installed=1
        fi
    else
        if curl -fsS -u "${sonar_login}:${sonar_password}" "http://localhost:${SONAR_PORT}/api/plugins/installed" 2>/dev/null | rg -q '"key":"cfamily"'; then
            cfamily_installed=1
        fi
    fi

    if [[ "${cfamily_installed}" -eq 0 ]]; then
        echo "Warning: C/C++ files detected, but SonarQube CFamily analyzer is not installed/enabled on this server." >&2
        echo "         Current analyzers may still scan Python/JS/HTML/etc only." >&2
        echo "         For C/C++ analysis, use a SonarQube edition/plugin that includes CFamily and pass --compile-commands." >&2
    fi
fi

echo "Running SonarQube scan for ${host_source_root}"
if ! docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    -e SONAR_HOST_URL="http://host.docker.internal:${SONAR_PORT}" \
    -v "${host_source_root}:/usr/src" \
    -w /usr/src \
    "${SCANNER_IMAGE}" \
    "${scanner_args[@]}"; then
    cat >&2 <<EOF
SonarQube scan failed.
If the scanner reported authorization errors, provide credentials explicitly:
  --sonar-token <token>
or:
  --sonar-login <user> --sonar-password <pass>

To generate a token on a local default SonarQube:
  curl -u admin:admin -X POST "http://localhost:${SONAR_PORT}/api/user_tokens/generate" --data-urlencode "name=devtools-cli-\$(date +%s)"
EOF
    exit 1
fi

if [[ -n "${resolved_project_key}" ]]; then
    echo "SonarQube dashboard: http://localhost:${SONAR_PORT}/dashboard?id=${resolved_project_key}"
fi
echo "SonarQube home:      http://localhost:${SONAR_PORT}"
