FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils \
    ca-certificates \
    git \
    perl \
    python3 \
    && if apt-get install -y --no-install-recommends linux-perf; then \
         true; \
       elif apt-get install -y --no-install-recommends linux-tools-generic; then \
         true; \
       else \
         apt-get install -y --no-install-recommends linux-tools-common; \
       fi \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/brendangregg/FlameGraph.git /opt/FlameGraph

WORKDIR /workspace

COPY docker/cpp-profiler-web/run_in_container.sh /usr/local/bin/run_profiler_in_container.sh
COPY docker/cpp-profiler-web/scripts /usr/local/bin/scripts
RUN chmod +x /usr/local/bin/run_profiler_in_container.sh

ENTRYPOINT ["/usr/local/bin/run_profiler_in_container.sh"]
