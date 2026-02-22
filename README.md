# DevTools: C++ Docker Tools

This repository provides Dockerized C++ development helpers that:
1. Configures and builds a CMake project with coverage flags.
2. Runs tests with `ctest`.
3. Generates HTML coverage using compiler-appropriate backends (`llvm-cov`, `gcovr`, or `fastcov`).
4. Serves coverage on localhost (default `8080`) with a tabbed dashboard.
5. Runs SonarQube static analysis and shows results on localhost (default `9000`).
6. Runs valgrind/cachegrind/callgrind in Docker and serves a tabbed localhost dashboard.

## Requirements

- Docker with permission to run containers
- Internet access (container image pulls / dependency installs)

## C++ Coverage

```bash
./tools/run-cpp-coverage.sh --cmake-root /absolute/path/to/project
```

### Required argument
- `-c, --cmake-root <path>`: CMake project root (must contain `CMakeLists.txt`).

### Optional arguments
- `-o, --os <image>`: Base image (default `ubuntu:24.04`)
- `--compiler <name>`: `g++|gcc|clang` (default `g++`)
- `-v, --compiler-version <major>`: compiler major version (example `14`, `18`)
- `-p, --port <port>`: coverage web port (default `8080`)
- `--build-type <type>`: CMake build type (default `Debug`)
- `--coverage-tool <name>`: `auto|gcovr|fastcov` (default `auto`)

### Example

```bash
./tools/run-cpp-coverage.sh \
  --cmake-root ../FixDecoder \
  --os ubuntu:24.04 \
  --compiler clang \
  --compiler-version 18 \
  --port 8080

# GCC + fastcov/genhtml backend
./tools/run-cpp-coverage.sh \
  --cmake-root ../FixDecoder \
  --compiler g++ \
  --coverage-tool fastcov \
  --port 8080
```

Coverage URLs:
- Dashboard (default landing page): `http://localhost:<port>/index.html`
- Raw main report: `http://localhost:<port>/coverage_main.html`
- Header inventory: `http://localhost:<port>/header_inventory.html`

## SonarQube Static Analysis

Run analysis for a source tree:

```bash
./tools/run-sonarqube-analysis.sh --source-root ../FixDecoder
```

Useful options:
- `-s, --source-root <path>`: project/source root to scan
- `-p, --port <port>`: SonarQube web port (default `9000`)
- `-k, --project-key <key>`: Sonar project key
- `-n, --project-name <name>`: Sonar project name
- `--project-version <version>`: project version string
- `--sonar-token <token>`: auth token (or set `SONAR_TOKEN`)
- `--compile-commands <path>`: `compile_commands.json` (for C/C++ analyzer support)
- `--sonar-image <image>`: override image tag (default now `sonarqube:community`)
- `--start-only`: start SonarQube only
- `--stop`: stop/remove SonarQube container for the selected port

Examples:

```bash
# Start SonarQube + run scan
./tools/run-sonarqube-analysis.sh \
  --source-root ../FixDecoder \
  --project-key fixdecoder \
  --project-name FixDecoder

# Run with compile_commands.json for C/C++
./tools/run-sonarqube-analysis.sh \
  --source-root ../FixDecoder \
  --compile-commands ../FixDecoder/build/compile_commands.json

# Stop SonarQube container on port 9000
./tools/run-sonarqube-analysis.sh --stop --port 9000
```

SonarQube URLs:
- Home: `http://localhost:<port>`
- Project dashboard: `http://localhost:<port>/dashboard?id=<project-key>`

## Grind Analysis Dashboard

Run valgrind/cachegrind/callgrind on an executable and open a tabbed web dashboard:

```bash
./tools/run-grind-analysis.sh --executable ../FixDecoder/build/Debug/bin/run_tests
```

Options:
- `-e, --executable <path>`: executable to run (required)
- `-t, --tools <list>`: comma-separated list from `cache,val,call` (default runs all)
- `-s, --source-root <path>`: source tree for file/line links (default current directory)
- `-w, --workdir <path>`: runtime working directory for executable (default current directory)
- `-p, --port <port>`: web dashboard port (default `8070`)
- `-- <exe args...>`: pass remaining args to the executable

Examples:

```bash
# run all tools (default)
./tools/run-grind-analysis.sh -e ../FixDecoder/build/Debug/bin/run_tests

# run only cachegrind + callgrind
./tools/run-grind-analysis.sh -e ../FixDecoder/build/Debug/bin/run_tests -t cache,call

# pass executable args
./tools/run-grind-analysis.sh -e ./build/my_app -t val -- --scenario perf --size 1000
```

Grind dashboard URL:
- `http://localhost:<port>/index.html`
