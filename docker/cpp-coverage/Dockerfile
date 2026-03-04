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
                openssh-client \
                libgtest-dev \
                ca-certificates \
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

# Install latest CMake (4.2.3)
RUN set -eux; \
    wget -q https://github.com/Kitware/CMake/releases/download/v4.2.3/cmake-4.2.3-linux-x86_64.sh && \
    chmod +x cmake-4.2.3-linux-x86_64.sh && \
    ./cmake-4.2.3-linux-x86_64.sh --skip-license --prefix=/usr/local && \
    rm cmake-4.2.3-linux-x86_64.sh

# Install Boost 1.90.0
RUN set -eux; \
    wget -q https://archives.boost.io/release/1.90.0/source/boost_1_90_0.tar.gz && \
    tar xzf boost_1_90_0.tar.gz && \
    cd boost_1_90_0 && \
    if [ "${COMPILER_FAMILY}" = "clang" ]; then BOOST_TOOLSET="clang"; CXX_BN="clang++"; CC_BN="clang"; else BOOST_TOOLSET="gcc"; CXX_BN="g++"; CC_BN="gcc"; fi; if [ -n "${COMPILER_VERSION}" ]; then ln -sf /usr/bin/${CXX_BN}-${COMPILER_VERSION} /usr/bin/${CXX_BN} && ln -sf /usr/bin/${CC_BN}-${COMPILER_VERSION} /usr/bin/${CC_BN}; fi; ./bootstrap.sh --with-toolset=${BOOST_TOOLSET} && \
    ./b2 -j$(nproc) install --prefix=/usr/local link=static --with-system --with-filesystem --with-graph --with-regex && \
    cd .. && \
    rm -rf boost_1_90_0 boost_1_90_0.tar.gz

# Install Google Test
RUN set -eux; \
    git clone https://github.com/google/googletest.git && \
    cd googletest && \
    cmake -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --parallel $(nproc) && \
    cmake --install build && \
    cd .. && \
    rm -rf googletest

RUN python3 -m pip install --no-cache-dir --break-system-packages fastcov

WORKDIR /workspace
COPY docker/cpp-coverage/run_in_container.sh /usr/local/bin/run_in_container.sh
COPY docker/cpp-coverage/scripts /usr/local/bin/scripts
RUN chmod +x /usr/local/bin/run_in_container.sh

ENTRYPOINT ["/usr/local/bin/run_in_container.sh"]
