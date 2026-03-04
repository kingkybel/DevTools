#!/usr/bin/env bash
set -euo pipefail

CMAKE_ROOT="${CMAKE_ROOT:-}"
PORT="${PORT:-8080}"
COMPILER_FAMILY="${COMPILER_FAMILY:-g++}"
COMPILER_VERSION="${COMPILER_VERSION:-}"
BUILD_TYPE="${BUILD_TYPE:-Coverage}"
COVERAGE_TOOL="${COVERAGE_TOOL:-auto}"

if [[ -z "${CMAKE_ROOT}" ]]; then
    echo "CMAKE_ROOT is required" >&2
    exit 2
fi

if [[ ! -d "${CMAKE_ROOT}" ]]; then
    echo "CMAKE_ROOT '${CMAKE_ROOT}' does not exist inside container" >&2
    exit 2
fi

# Initialize and update submodules if they are not yet available
if [[ -d "${CMAKE_ROOT}/.git" ]]; then
    git config --global --add safe.directory "${CMAKE_ROOT}"
    git config --global url."https://github.com/".insteadOf git@github.com:
    echo "Updating submodules..."
    git -C "${CMAKE_ROOT}" submodule update --init --recursive
    # Build and install submodules
    for sub in TypeTraits DebugTrace ContainerConvert StringUtilities; do
        if [[ -d "${CMAKE_ROOT}/${sub}" ]]; then
            echo "Building and installing ${sub}..."
            cmake -S "${CMAKE_ROOT}/${sub}" -B "/tmp/build-${sub}" -DCMAKE_INSTALL_PREFIX=/usr/local
            cmake --build "/tmp/build-${sub}" --parallel $(nproc)
            cmake --install "/tmp/build-${sub}"
        fi
    done
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
    -DCMAKE_CXX_COMPILER="${CXX_COMPILER}" 
    
    
    

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
        included_header_count="$(python3 /usr/local/bin/scripts/check_headers.py "${COVERAGE_EXPORT_JSON}" "${INCLUDE_DIR}/")"
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
        cd "${CMAKE_ROOT}" && gcovr --verbose --gcov-ignore-parse-errors \
            --root "${CMAKE_ROOT}" \
            --object-directory "${BUILD_DIR}" \
            --filter "${SOURCE_DIR}" \
            --filter "${INCLUDE_DIR}" \
            --html-details "${COVERAGE_DIR}/index.html" \
            --json "${COVERAGE_EXPORT_JSON}" \
            --print-summary \
            --exclude-directories '.*/(_deps|build|cmake-build.*)/.*' \
            --gcov-executable gcov \
            "${BUILD_DIR}" 
    fi
fi

if command -v python3 >/dev/null 2>&1; then
    python3 /usr/local/bin/scripts/generate_report.py "${COVERAGE_EXPORT_JSON}" "${LCOV_INFO_PATH}" "${INCLUDE_DIR}" "${COVERAGE_DIR}" "${CMAKE_ROOT}"
fi

echo "Coverage report available at: http://localhost:${PORT}/index.html"
echo "Raw main report available at: http://localhost:${PORT}/coverage_main.html"
echo "Header inventory available at: http://localhost:${PORT}/header_inventory.html"
echo "Overview page available at: http://localhost:${PORT}/overview.html"
exec python3 -m http.server --bind 0.0.0.0 "${PORT}" --directory "${COVERAGE_DIR}"
