#!/usr/bin/env bash
set -euo pipefail

EXE_PATH="${EXE_PATH:-}"
SOURCE_ROOT="${SOURCE_ROOT:-}"
EXEC_WORKDIR="${EXEC_WORKDIR:-}"
PORT="${PORT:-8060}"
PERF_FREQ="${PERF_FREQ:-99}"
EXE_ARGS_RAW="${EXE_ARGS:-}"

[[ -n "${EXE_PATH}" ]] || { echo "EXE_PATH is required" >&2; exit 2; }
[[ -n "${SOURCE_ROOT}" ]] || { echo "SOURCE_ROOT is required" >&2; exit 2; }
[[ -n "${EXEC_WORKDIR}" ]] || { echo "EXEC_WORKDIR is required" >&2; exit 2; }

PERF_BIN="$(command -v perf || true)"
STACKCOLLAPSE_BIN="/opt/FlameGraph/stackcollapse-perf.pl"
FLAMEGRAPH_BIN="/opt/FlameGraph/flamegraph.pl"
RESULT_DIR="/tmp/profiler-results"

if [[ -n "${PERF_BIN}" ]] && ! "${PERF_BIN}" --version >/dev/null 2>&1; then
    PERF_BIN=""
fi

if [[ -z "${PERF_BIN}" ]]; then
    mapfile -t perf_candidates < <(compgen -G "/usr/lib/linux-tools/*/perf" || true)
    if [[ ${#perf_candidates[@]} -gt 0 ]]; then
        mapfile -t perf_candidates < <(printf '%s\n' "${perf_candidates[@]}" | sort -V)
        PERF_BIN="${perf_candidates[$((${#perf_candidates[@]} - 1))]}"
        echo "[profiler] using fallback perf binary: ${PERF_BIN}"
    fi
fi

if [[ -z "${PERF_BIN}" ]]; then
    echo "perf not found in container PATH (${PATH})" >&2
    exit 2
fi

if [[ ! -x "${STACKCOLLAPSE_BIN}" || ! -x "${FLAMEGRAPH_BIN}" ]]; then
    echo "FlameGraph scripts not found under /opt/FlameGraph" >&2
    exit 2
fi

rm -rf "${RESULT_DIR}"
mkdir -p "${RESULT_DIR}"

read -r -a EXE_ARGS <<< "${EXE_ARGS_RAW}"

interrupted=0
current_pid=""

on_interrupt() {
    interrupted=1
    if [[ -n "${current_pid}" ]]; then
        kill -INT "${current_pid}" 2>/dev/null || true
    fi
}
trap on_interrupt INT TERM

cd "${EXEC_WORKDIR}"

echo "[profiler] recording with perf (freq=${PERF_FREQ}Hz)"
set +e
"${PERF_BIN}" record -F "${PERF_FREQ}" -g --call-graph dwarf -o "${RESULT_DIR}/perf.data" -- "${EXE_PATH}" "${EXE_ARGS[@]}" 2>"${RESULT_DIR}/perf_record.stderr" &
current_pid=$!
wait "${current_pid}"
record_rc=$?
current_pid=""
set -e

if [[ ${record_rc} -ne 0 && ${interrupted} -eq 0 ]]; then
    echo "[profiler] perf record failed (exit ${record_rc})" >&2
fi

if [[ -f "${RESULT_DIR}/perf.data" ]]; then
    "${PERF_BIN}" report --stdio -i "${RESULT_DIR}/perf.data" > "${RESULT_DIR}/perf_report.txt" 2>"${RESULT_DIR}/perf_report.stderr" || true
    "${PERF_BIN}" script -i "${RESULT_DIR}/perf.data" > "${RESULT_DIR}/perf.script" 2>"${RESULT_DIR}/perf_script.stderr" || true

    if [[ -s "${RESULT_DIR}/perf.script" ]]; then
        "${STACKCOLLAPSE_BIN}" "${RESULT_DIR}/perf.script" > "${RESULT_DIR}/perf.folded" || true
    fi

    if [[ -s "${RESULT_DIR}/perf.folded" ]]; then
        "${FLAMEGRAPH_BIN}" --title "CPU Flamegraph" "${RESULT_DIR}/perf.folded" > "${RESULT_DIR}/flamegraph.svg" || true
    fi
fi

python3 /usr/local/bin/scripts/generate_report.py "${RESULT_DIR}" "${EXE_PATH}" "${SOURCE_ROOT}" "${PERF_FREQ}" "${record_rc}" "${EXE_ARGS_RAW}"

echo "Profiler dashboard: http://localhost:${PORT}/index.html"
exec python3 -m http.server --bind 0.0.0.0 "${PORT}" --directory "${RESULT_DIR}"
