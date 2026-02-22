#!/usr/bin/env bash
set -euo pipefail

CMAKE_ROOT="${CMAKE_ROOT:-}"
PORT="${PORT:-8080}"
COMPILER_FAMILY="${COMPILER_FAMILY:-g++}"
COMPILER_VERSION="${COMPILER_VERSION:-}"
BUILD_TYPE="${BUILD_TYPE:-Debug}"
COVERAGE_TOOL="${COVERAGE_TOOL:-auto}"

if [[ -z "${CMAKE_ROOT}" ]]; then
    echo "CMAKE_ROOT is required" >&2
    exit 2
fi

if [[ ! -d "${CMAKE_ROOT}" ]]; then
    echo "CMAKE_ROOT '${CMAKE_ROOT}' does not exist inside container" >&2
    exit 2
fi

BUILD_DIR="/tmp/cmake-build"
COVERAGE_DIR="/tmp/coverage"
PROFILE_DIR="/tmp/llvm-profiles"
SOURCE_DIR="${CMAKE_ROOT}/src"
INCLUDE_DIR="${CMAKE_ROOT}/include"
COVERAGE_EXPORT_JSON="${PROFILE_DIR}/coverage-export.json"
LCOV_INFO_PATH="${PROFILE_DIR}/coverage.info"

rm -rf "${BUILD_DIR}" "${COVERAGE_DIR}" "${PROFILE_DIR}"
mkdir -p "${BUILD_DIR}" "${COVERAGE_DIR}" "${PROFILE_DIR}"

find_llvm_tool() {
    local base="$1"
    local candidate=""
    for candidate in \
        "${base}" \
        "${base}-${COMPILER_VERSION}" \
        "${base}-21" "${base}-20" "${base}-19" "${base}-18" "${base}-17"; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            command -v "${candidate}"
            return 0
        fi
    done
    for candidate in /usr/lib/llvm*/bin/"${base}"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

case "${COMPILER_FAMILY}" in
    gcc|g++)
        if [[ -n "${COMPILER_VERSION}" ]] && command -v "g++-${COMPILER_VERSION}" >/dev/null 2>&1 && command -v "gcc-${COMPILER_VERSION}" >/dev/null 2>&1; then
            CXX_COMPILER="g++-${COMPILER_VERSION}"
            C_COMPILER="gcc-${COMPILER_VERSION}"
        else
            CXX_COMPILER="g++"
            C_COMPILER="gcc"
        fi
        ;;
    clang)
        if [[ -n "${COMPILER_VERSION}" ]] && command -v "clang++-${COMPILER_VERSION}" >/dev/null 2>&1 && command -v "clang-${COMPILER_VERSION}" >/dev/null 2>&1; then
            CXX_COMPILER="clang++-${COMPILER_VERSION}"
            C_COMPILER="clang-${COMPILER_VERSION}"
        else
            CXX_COMPILER="clang++"
            C_COMPILER="clang"
        fi
        ;;
    *)
        echo "Unsupported compiler family '${COMPILER_FAMILY}'" >&2
        exit 2
        ;;
esac

case "${COVERAGE_TOOL}" in
    auto|gcovr|fastcov)
        ;;
    *)
        echo "Unsupported COVERAGE_TOOL '${COVERAGE_TOOL}' (use auto|gcovr|fastcov)" >&2
        exit 2
        ;;
esac

if [[ "${COMPILER_FAMILY}" == "clang" ]]; then
    C_COVERAGE_FLAGS="-O0 -g -fprofile-instr-generate -fcoverage-mapping"
    CXX_COVERAGE_FLAGS="-O0 -g -fprofile-instr-generate -fcoverage-mapping"
    EXE_LINKER_FLAGS="-fprofile-instr-generate"
else
    C_COVERAGE_FLAGS="--coverage -O0 -g"
    CXX_COVERAGE_FLAGS="--coverage -O0 -g"
    EXE_LINKER_FLAGS=""
fi

cmake -S "${CMAKE_ROOT}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_C_COMPILER="${C_COMPILER}" \
    -DCMAKE_CXX_COMPILER="${CXX_COMPILER}" \
    -DCMAKE_C_FLAGS="${C_COVERAGE_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXX_COVERAGE_FLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${EXE_LINKER_FLAGS}"

cmake --build "${BUILD_DIR}" --parallel "$(nproc)"
if [[ "${COMPILER_FAMILY}" == "clang" ]]; then
    if [[ "${COVERAGE_TOOL}" == "fastcov" ]]; then
        echo "COVERAGE_TOOL=fastcov is not supported with clang. Use auto or gcovr equivalent LLVM flow." >&2
        exit 2
    fi

    LLVM_COV_BIN="$(find_llvm_tool llvm-cov || true)"
    LLVM_PROFDATA_BIN="$(find_llvm_tool llvm-profdata || true)"
    if [[ -z "${LLVM_COV_BIN}" || -z "${LLVM_PROFDATA_BIN}" ]]; then
        echo "llvm-cov/llvm-profdata not found for clang coverage" >&2
        exit 2
    fi

    LLVM_PROFILE_FILE="${PROFILE_DIR}/unit-%p.profraw" \
        ctest --test-dir "${BUILD_DIR}" --output-on-failure

    shopt -s nullglob
    profraw_files=("${PROFILE_DIR}"/*.profraw)
    shopt -u nullglob
    if [[ ${#profraw_files[@]} -eq 0 ]]; then
        echo "No LLVM profile files were generated. Coverage cannot be produced." >&2
        exit 2
    fi

    "${LLVM_PROFDATA_BIN}" merge -sparse "${profraw_files[@]}" -o "${PROFILE_DIR}/merged.profdata"

    shopt -s nullglob
    binaries=("${BUILD_DIR}"/"${BUILD_TYPE}"/bin/*)
    shopt -u nullglob
    if [[ ${#binaries[@]} -eq 0 ]]; then
        echo "No built binaries found under ${BUILD_DIR}/${BUILD_TYPE}/bin" >&2
        exit 2
    fi
    primary_bin="${binaries[0]}"

    mapfile -t project_sources < <(
        find "${SOURCE_DIR}" "${INCLUDE_DIR}" -type f \
            \( -name "*.cc" -o -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" -o -name "*.hh" -o -name "*.hxx" -o -name "*.ipp" -o -name "*.tpp" -o -name "*.inl" \) \
            2>/dev/null | sort
    )
    if [[ ${#project_sources[@]} -eq 0 ]]; then
        echo "No sources found under ${CMAKE_ROOT}/src or ${CMAKE_ROOT}/include" >&2
        exit 2
    fi

    llvm_object_args=()
    if [[ ${#binaries[@]} -gt 1 ]]; then
        for bin in "${binaries[@]:1}"; do
            llvm_object_args+=(-object "${bin}")
        done
    fi

    "${LLVM_COV_BIN}" report "${primary_bin}" \
        "${llvm_object_args[@]}" \
        -instr-profile="${PROFILE_DIR}/merged.profdata" \
        -ignore-filename-regex='(^|.*/)(test|tests|_deps|googletest|tinyxml2|/usr/include/|usr/include/)' \
        "${project_sources[@]}"

    "${LLVM_COV_BIN}" show "${primary_bin}" \
        "${llvm_object_args[@]}" \
        -instr-profile="${PROFILE_DIR}/merged.profdata" \
        -ignore-filename-regex='(^|.*/)(test|tests|_deps|googletest|tinyxml2|/usr/include/|usr/include/)' \
        -format=html \
        -output-dir="${COVERAGE_DIR}" \
        "${project_sources[@]}"

    "${LLVM_COV_BIN}" export "${primary_bin}" \
        "${llvm_object_args[@]}" \
        -instr-profile="${PROFILE_DIR}/merged.profdata" \
        -ignore-filename-regex='(^|.*/)(test|tests|_deps|googletest|tinyxml2|/usr/include/|usr/include/)' \
        "${project_sources[@]}" > "${COVERAGE_EXPORT_JSON}"

    if command -v python3 >/dev/null 2>&1; then
        included_header_count="$(
            python3 - "${COVERAGE_EXPORT_JSON}" "${INCLUDE_DIR}/" <<'PY'
import json
import sys

path = sys.argv[1]
prefix = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

seen = set()
for entry in data.get("data", []):
    for fobj in entry.get("files", []):
        filename = fobj.get("filename", "")
        if filename.startswith(prefix):
            seen.add(filename)

print(len(seen))
PY
        )"
        if [[ "${included_header_count}" == "0" ]]; then
            echo "Note: no include/ header had instrumented executable regions in this run." >&2
            echo "Headers with declarations only are scanned but won't appear in coverage totals." >&2
        fi
    fi
else
    ctest --test-dir "${BUILD_DIR}" --output-on-failure
    if [[ "${COVERAGE_TOOL}" == "fastcov" ]]; then
        FASTCOV_BIN="$(command -v fastcov || true)"
        if [[ -z "${FASTCOV_BIN}" ]]; then
            FASTCOV_BIN="$(command -v fastcov.py || true)"
        fi
        if [[ -z "${FASTCOV_BIN}" ]]; then
            echo "fastcov binary not found in container image" >&2
            exit 2
        fi
        if ! command -v genhtml >/dev/null 2>&1; then
            echo "genhtml (lcov package) not found in container image" >&2
            exit 2
        fi

        "${FASTCOV_BIN}" \
            -d "${BUILD_DIR}" \
            --gcov gcov \
            --exclude /usr/include test tests _deps build cmake-build \
            --include "${SOURCE_DIR}" "${INCLUDE_DIR}" \
            --lcov \
            -o "${LCOV_INFO_PATH}"

        genhtml \
            --title "C++ Coverage Report" \
            --output-directory "${COVERAGE_DIR}" \
            "${LCOV_INFO_PATH}" >/dev/null
    else
        gcovr \
            --root "${CMAKE_ROOT}" \
            --object-directory "${BUILD_DIR}" \
            --filter "${SOURCE_DIR}" \
            --filter "${INCLUDE_DIR}" \
            --html-details "${COVERAGE_DIR}/index.html" \
            --json "${COVERAGE_EXPORT_JSON}" \
            --print-summary \
            --exclude-directories '.*/(test|tests|build|cmake-build.*|_deps)/.*' \
            --gcov-executable gcov
    fi
fi

if command -v python3 >/dev/null 2>&1; then
    python3 - "${COVERAGE_EXPORT_JSON}" "${LCOV_INFO_PATH}" "${INCLUDE_DIR}" "${COVERAGE_DIR}" <<'PY'
import html
import json
import os
import pathlib
import sys

coverage_json_path = pathlib.Path(sys.argv[1])
lcov_info_path = pathlib.Path(sys.argv[2])
include_dir = pathlib.Path(sys.argv[3])
coverage_dir = pathlib.Path(sys.argv[4])

header_suffixes = {".h", ".hpp", ".hh", ".hxx", ".ipp", ".tpp", ".inl"}

def list_headers(root: pathlib.Path):
    if not root.is_dir():
        return []
    return sorted(
        p for p in root.rglob("*")
        if p.is_file() and p.suffix.lower() in header_suffixes
    )

def extract_metrics_from_file_obj(file_obj):
    # LLVM export format: file_obj["summary"]["lines"] has count/covered
    summary = file_obj.get("summary", {})
    lines = summary.get("lines", {})
    if isinstance(lines, dict) and ("count" in lines or "covered" in lines):
        total = int(lines.get("count", 0) or 0)
        covered = int(lines.get("covered", 0) or 0)
        return total, covered

    # gcovr JSON format fallback: file_obj["lines"] with execution counts
    if isinstance(file_obj.get("lines"), list):
        total = 0
        covered = 0
        for line in file_obj["lines"]:
            if not isinstance(line, dict):
                continue
            if "count" not in line:
                continue
            count = line.get("count")
            if isinstance(count, int):
                total += 1
                if count > 0:
                    covered += 1
        return total, covered

    # Alternative gcovr summary fields if present.
    total = int(file_obj.get("line_total", 0) or 0)
    covered = int(file_obj.get("line_covered", 0) or 0)
    return total, covered

metrics = {}
if coverage_json_path.is_file():
    with coverage_json_path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)

    # LLVM export layout.
    if isinstance(data.get("data"), list):
        for unit in data["data"]:
            for fobj in unit.get("files", []):
                filename = fobj.get("filename")
                if not filename:
                    continue
                total, covered = extract_metrics_from_file_obj(fobj)
                metrics[os.path.abspath(filename)] = (total, covered)

    # gcovr JSON layout.
    if isinstance(data.get("files"), list):
        for fobj in data["files"]:
            filename = fobj.get("file") or fobj.get("filename")
            if not filename:
                continue
            total, covered = extract_metrics_from_file_obj(fobj)
            metrics[os.path.abspath(filename)] = (total, covered)

# LCOV fallback (used by fastcov/genhtml path)
if lcov_info_path.is_file():
    current_file = None
    total = 0
    covered = 0
    with lcov_info_path.open("r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("SF:"):
                current_file = os.path.abspath(line[3:])
                total = 0
                covered = 0
            elif line.startswith("DA:"):
                if current_file is None:
                    continue
                payload = line[3:]
                parts = payload.split(",")
                if len(parts) < 2:
                    continue
                try:
                    count = int(parts[1])
                except ValueError:
                    continue
                total += 1
                if count > 0:
                    covered += 1
            elif line == "end_of_record":
                if current_file is not None:
                    prev_total, prev_covered = metrics.get(current_file, (0, 0))
                    metrics[current_file] = (max(prev_total, total), max(prev_covered, covered))
                current_file = None

headers = list_headers(include_dir)
rows = []
counts = {"covered": 0, "uncovered": 0, "non_instrumentable": 0}

for header in headers:
    abs_header = os.path.abspath(str(header))
    total, covered = metrics.get(abs_header, (0, 0))

    if total <= 0:
        status = "non-instrumentable"
        counts["non_instrumentable"] += 1
    elif covered > 0:
        status = "instrumented-covered"
        counts["covered"] += 1
    else:
        status = "instrumented-uncovered"
        counts["uncovered"] += 1

    rows.append(
        (
            str(header),
            status,
            total,
            covered,
            f"{(covered / total * 100.0):.2f}%" if total > 0 else "n/a",
        )
    )

def render_row(row):
    path, status, total, covered, pct = row
    css = {
        "instrumented-covered": "covered",
        "instrumented-uncovered": "uncovered",
        "non-instrumentable": "noninst",
    }[status]
    return (
        f"<tr class='{css}'>"
        f"<td><code>{html.escape(path)}</code></td>"
        f"<td>{html.escape(status)}</td>"
        f"<td>{total}</td>"
        f"<td>{covered}</td>"
        f"<td>{pct}</td>"
        "</tr>"
    )

header_inventory_html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Header Inventory</title>
  <style>
    body {{ font-family: system-ui, sans-serif; margin: 1.5rem; }}
    .summary {{ display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1rem; }}
    .pill {{ padding: 0.4rem 0.7rem; border-radius: 999px; font-size: 0.9rem; }}
    .covered-pill {{ background: #d1fae5; color: #065f46; }}
    .uncovered-pill {{ background: #fee2e2; color: #991b1b; }}
    .noninst-pill {{ background: #e5e7eb; color: #374151; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ border: 1px solid #d1d5db; padding: 0.5rem; text-align: left; }}
    th {{ background: #f3f4f6; }}
    tr.covered {{ background: #ecfdf5; }}
    tr.uncovered {{ background: #fef2f2; }}
    tr.noninst {{ background: #f9fafb; }}
  </style>
</head>
<body>
  <h1>Include Header Inventory</h1>
  <p>Classification uses coverage data plus files discovered under <code>{html.escape(str(include_dir))}</code>.</p>
  <div class="summary">
    <span class="pill covered-pill">Instrumented + covered: {counts["covered"]}</span>
    <span class="pill uncovered-pill">Instrumented + uncovered: {counts["uncovered"]}</span>
    <span class="pill noninst-pill">Non-instrumentable: {counts["non_instrumentable"]}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Header</th>
        <th>Status</th>
        <th>Coverable Lines</th>
        <th>Covered Lines</th>
        <th>Coverage</th>
      </tr>
    </thead>
    <tbody>
      {"".join(render_row(row) for row in rows)}
    </tbody>
  </table>
</body>
</html>
"""

coverage_dir.mkdir(parents=True, exist_ok=True)
(coverage_dir / "header_inventory.html").write_text(header_inventory_html, encoding="utf-8")

overview_html = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Coverage Dashboard</title>
  <style>
    body { margin: 0; font-family: system-ui, sans-serif; background: #f8fafc; color: #0f172a; }
    .top { padding: 1rem 1rem 0.6rem; background: #ffffff; border-bottom: 1px solid #e2e8f0; position: sticky; top: 0; z-index: 20; }
    .title { margin: 0 0 0.75rem 0; font-size: 1.1rem; font-weight: 650; }
    .tabs { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .tab-btn { border: 1px solid #cbd5e1; background: #f8fafc; color: #0f172a; border-radius: 0.5rem; padding: 0.45rem 0.8rem; cursor: pointer; font-weight: 600; }
    .tab-btn.active { background: #0f172a; color: #f8fafc; border-color: #0f172a; }
    .panel { display: none; padding: 1rem; }
    .panel.active { display: block; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 0.8rem; margin-bottom: 1rem; }
    .card { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 0.75rem; padding: 0.85rem; }
    .card h2 { margin: 0 0 0.35rem; font-size: 0.95rem; }
    .frame-wrap { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 0.75rem; overflow: hidden; }
    iframe { width: 100%; height: calc(100vh - 11rem); border: 0; display: block; background: #ffffff; }
    code { background: #e2e8f0; border-radius: 0.3rem; padding: 0.1rem 0.3rem; }
    a { color: #1d4ed8; }
  </style>
</head>
<body>
  <div class="top">
    <h1 class="title">Coverage Dashboard</h1>
    <div class="tabs">
      <button class="tab-btn active" data-tab="overview">Overview</button>
      <button class="tab-btn" data-tab="main">Main Report</button>
      <button class="tab-btn" data-tab="headers">Header Inventory</button>
    </div>
  </div>

  <section class="panel active" data-panel="overview">
    <div class="cards">
      <div class="card">
        <h2>Main Coverage Report</h2>
        <div>Full source and line-by-line coverage pages.</div>
      </div>
      <div class="card">
        <h2>Header Inventory</h2>
        <div>Headers under <code>include/</code> classified as covered, uncovered, or non-instrumentable.</div>
      </div>
      <div class="card">
        <h2>Direct Links</h2>
        <div><a href="/coverage_main.html" target="_blank" rel="noopener">Open main report</a></div>
        <div><a href="/header_inventory.html" target="_blank" rel="noopener">Open header inventory</a></div>
      </div>
    </div>
  </section>

  <section class="panel" data-panel="main">
    <div class="frame-wrap"><iframe src="/coverage_main.html" title="Main Coverage Report"></iframe></div>
  </section>

  <section class="panel" data-panel="headers">
    <div class="frame-wrap"><iframe src="/header_inventory.html" title="Header Inventory"></iframe></div>
  </section>

  <script>
    (function () {
      const buttons = Array.from(document.querySelectorAll('.tab-btn'));
      const panels = Array.from(document.querySelectorAll('.panel'));
      function setTab(name) {
        buttons.forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
        panels.forEach((p) => p.classList.toggle('active', p.dataset.panel === name));
      }
      buttons.forEach((btn) => btn.addEventListener('click', () => setTab(btn.dataset.tab)));
    })();
  </script>
</body>
</html>
"""
main_report = coverage_dir / "index.html"
if main_report.is_file():
    # Keep the tool-generated report as a dedicated page.
    main_report.rename(coverage_dir / "coverage_main.html")

# Publish the tabbed dashboard as both overview and default index.
(coverage_dir / "overview.html").write_text(overview_html, encoding="utf-8")
(coverage_dir / "index.html").write_text(overview_html, encoding="utf-8")
PY
fi

echo "Coverage report available at: http://localhost:${PORT}/index.html"
echo "Raw main report available at: http://localhost:${PORT}/coverage_main.html"
echo "Header inventory available at: http://localhost:${PORT}/header_inventory.html"
echo "Overview page available at: http://localhost:${PORT}/overview.html"
exec python3 -m http.server --bind 0.0.0.0 "${PORT}" --directory "${COVERAGE_DIR}"
