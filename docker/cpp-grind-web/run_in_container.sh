#!/usr/bin/env bash
set -euo pipefail

EXE_PATH="${EXE_PATH:-}"
SOURCE_ROOT="${SOURCE_ROOT:-}"
EXEC_WORKDIR="${EXEC_WORKDIR:-}"
TOOLS="${TOOLS:-cache,val,call}"
PORT="${PORT:-8070}"
EXE_ARGS_RAW="${EXE_ARGS:-}"

[[ -n "${EXE_PATH}" ]] || { echo "EXE_PATH is required" >&2; exit 2; }
[[ -n "${SOURCE_ROOT}" ]] || { echo "SOURCE_ROOT is required" >&2; exit 2; }
[[ -n "${EXEC_WORKDIR}" ]] || { echo "EXEC_WORKDIR is required" >&2; exit 2; }

RESULT_DIR="/tmp/grind-results"
SRC_HTML_DIR="${RESULT_DIR}/src"
VALGRIND_BIN="$(command -v valgrind || true)"
CG_ANNOTATE_BIN="$(command -v cg_annotate || true)"
CALLGRIND_ANNOTATE_BIN="$(command -v callgrind_annotate || true)"

if [[ -z "${VALGRIND_BIN}" ]]; then
    echo "valgrind not found in container PATH (${PATH})" >&2
    exit 2
fi

rm -rf "${RESULT_DIR}"
mkdir -p "${RESULT_DIR}" "${SRC_HTML_DIR}"

IFS=',' read -r -a TOOL_LIST <<< "${TOOLS}"
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

run_tool() {
    local tag="$1"
    shift
    echo "[grind] running ${tag}"
    set +e
    "$@" &
    current_pid=$!
    wait "${current_pid}"
    rc=$?
    current_pid=""
    set -e
    if [[ ${rc} -ne 0 && ${interrupted} -eq 0 ]]; then
        echo "[grind] ${tag} failed (exit ${rc})" >&2
    fi
}

cd "${EXEC_WORKDIR}"

for tool in "${TOOL_LIST[@]}"; do
    [[ ${interrupted} -eq 0 ]] || break
    case "${tool}" in
        val)
            run_tool "valgrind" \
                "${VALGRIND_BIN}" --tool=memcheck --leak-check=full --show-leak-kinds=all \
                --track-origins=yes --error-limit=no --num-callers=40 \
                --xml=yes --xml-file="${RESULT_DIR}/valgrind.xml" \
                --log-file="${RESULT_DIR}/valgrind.log" \
                "${EXE_PATH}" "${EXE_ARGS[@]}"
            ;;
        cache)
            run_tool "cachegrind" \
                "${VALGRIND_BIN}" --tool=cachegrind \
                --cachegrind-out-file="${RESULT_DIR}/cachegrind.out" \
                --log-file="${RESULT_DIR}/cachegrind.log" \
                "${EXE_PATH}" "${EXE_ARGS[@]}"
            if [[ -f "${RESULT_DIR}/cachegrind.out" && -n "${CG_ANNOTATE_BIN}" ]]; then
                "${CG_ANNOTATE_BIN}" "${RESULT_DIR}/cachegrind.out" > "${RESULT_DIR}/cachegrind.txt" || true
            fi
            ;;
        call)
            run_tool "callgrind" \
                "${VALGRIND_BIN}" --tool=callgrind \
                --callgrind-out-file="${RESULT_DIR}/callgrind.out" \
                --log-file="${RESULT_DIR}/callgrind.log" \
                "${EXE_PATH}" "${EXE_ARGS[@]}"
            if [[ -f "${RESULT_DIR}/callgrind.out" && -n "${CALLGRIND_ANNOTATE_BIN}" ]]; then
                "${CALLGRIND_ANNOTATE_BIN}" "${RESULT_DIR}/callgrind.out" > "${RESULT_DIR}/callgrind.txt" || true
            fi
            ;;
        *)
            echo "Unknown tool '${tool}'" >&2
            ;;
    esac
done

python3 /usr/local/bin/scripts/generate_report.py "${SOURCE_ROOT}" "${RESULT_DIR}"

echo "Grind dashboard: http://localhost:${PORT}/index.html"
exec python3 -m http.server --bind 0.0.0.0 "${PORT}" --directory "${RESULT_DIR}"
