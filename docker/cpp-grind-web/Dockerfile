FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    python3 \
    valgrind \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY docker/cpp-grind-web/run_in_container.sh /usr/local/bin/run_grind_in_container.sh
RUN chmod +x /usr/local/bin/run_grind_in_container.sh

ENTRYPOINT ["/usr/local/bin/run_grind_in_container.sh"]
