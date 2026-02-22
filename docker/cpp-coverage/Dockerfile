ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG COMPILER_FAMILY=g++
ARG COMPILER_VERSION=
ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    . /etc/os-release; \
    case "${ID}" in \
        ubuntu|debian) \
            apt-get update; \
            apt-get install -y --no-install-recommends \
                ca-certificates \
                cmake \
                curl \
                git \
                lcov \
                make \
                ninja-build \
                python3 \
                python3-pip \
                wget; \
            if [ "${COMPILER_FAMILY}" = "gcc" ] || [ "${COMPILER_FAMILY}" = "g++" ]; then \
                if [ -n "${COMPILER_VERSION}" ] && apt-cache show "g++-${COMPILER_VERSION}" >/dev/null 2>&1; then \
                    apt-get install -y --no-install-recommends "gcc-${COMPILER_VERSION}" "g++-${COMPILER_VERSION}" gcovr; \
                else \
                    apt-get install -y --no-install-recommends gcc g++ gcovr; \
                fi; \
            elif [ "${COMPILER_FAMILY}" = "clang" ]; then \
                if [ -n "${COMPILER_VERSION}" ] && apt-cache show "clang-${COMPILER_VERSION}" >/dev/null 2>&1; then \
                    apt-get install -y --no-install-recommends "clang-${COMPILER_VERSION}" "lld-${COMPILER_VERSION}" "llvm-${COMPILER_VERSION}" gcovr; \
                    if apt-cache show "libclang-rt-${COMPILER_VERSION}-dev" >/dev/null 2>&1; then \
                        apt-get install -y --no-install-recommends "libclang-rt-${COMPILER_VERSION}-dev"; \
                    elif apt-cache show "compiler-rt-${COMPILER_VERSION}" >/dev/null 2>&1; then \
                        apt-get install -y --no-install-recommends "compiler-rt-${COMPILER_VERSION}"; \
                    elif apt-cache show "libclang-rt-dev" >/dev/null 2>&1; then \
                        apt-get install -y --no-install-recommends libclang-rt-dev; \
                    else \
                        apt-get install -y --no-install-recommends compiler-rt; \
                    fi; \
                else \
                    if apt-cache show "libclang-rt-dev" >/dev/null 2>&1; then \
                        apt-get install -y --no-install-recommends clang lld llvm libclang-rt-dev gcovr; \
                    else \
                        apt-get install -y --no-install-recommends clang lld llvm compiler-rt gcovr; \
                    fi; \
                fi; \
            else \
                echo "Unsupported COMPILER_FAMILY: ${COMPILER_FAMILY}" >&2; \
                exit 2; \
            fi; \
            rm -rf /var/lib/apt/lists/*; \
            ;; \
        fedora) \
            dnf -y install \
                ca-certificates \
                cmake \
                curl \
                git \
                lcov \
                make \
                ninja-build \
                which \
                python3 \
                python3-pip \
                wget \
                gcovr; \
            if [ "${COMPILER_FAMILY}" = "gcc" ] || [ "${COMPILER_FAMILY}" = "g++" ]; then \
                dnf -y install gcc gcc-c++; \
            elif [ "${COMPILER_FAMILY}" = "clang" ]; then \
                dnf -y install clang lld llvm gcc gcc-c++; \
            else \
                echo "Unsupported COMPILER_FAMILY: ${COMPILER_FAMILY}" >&2; \
                exit 2; \
            fi; \
            dnf clean all; \
            ;; \
        alpine) \
            apk add --no-cache \
                bash \
                ca-certificates \
                cmake \
                curl \
                git \
                lcov \
                make \
                ninja-build \
                python3 \
                py3-pip \
                gcovr \
                wget \
                build-base; \
            if [ "${COMPILER_FAMILY}" = "clang" ]; then \
                apk add --no-cache clang lld llvm compiler-rt; \
            fi; \
            ;; \
        *) \
            echo "Unsupported distro ID: ${ID}" >&2; \
            exit 2; \
            ;; \
    esac

RUN python3 -m pip install --no-cache-dir --break-system-packages fastcov

WORKDIR /workspace
COPY docker/cpp-coverage/run_in_container.sh /usr/local/bin/run_in_container.sh
RUN chmod +x /usr/local/bin/run_in_container.sh

ENTRYPOINT ["/usr/local/bin/run_in_container.sh"]
