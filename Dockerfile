# Maple — local mode in a container.
#
# Ships the official release bundle (the `maple` binary + `libchdb.so`, its
# embedded ClickHouse). This is the only Maple distribution that actually runs
# as a plain long-lived process — the apps/* Dockerfiles in the upstream repo
# target a Cloudflare Workers runtime and do not build. See NOTES.md.

FROM debian:bookworm-slim AS fetch

ARG MAPLE_VERSION=v0.0.18
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# The release publishes one bundle per Rust target triple. Map Docker's
# TARGETARCH onto it so `docker build --platform` picks the right one.
RUN set -eux; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      arm64) target=aarch64-unknown-linux-gnu ;; \
      amd64) target=x86_64-unknown-linux-gnu ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/MapleTechLabs/maple/releases/download/${MAPLE_VERSION}"; \
    file="maple-${MAPLE_VERSION}-${target}.tar.gz"; \
    curl -fsSL -o /tmp/maple.tar.gz "${base}/${file}"; \
    curl -fsSL -o /tmp/maple.sha256 "${base}/${file}.sha256"; \
    # The .sha256 names the original file; check against our local name.
    echo "$(cut -d' ' -f1 /tmp/maple.sha256)  /tmp/maple.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/maple; \
    tar -xzf /tmp/maple.tar.gz -C /tmp; \
    mv /tmp/maple-*/maple /opt/maple/maple; \
    mv /tmp/maple-*/libchdb.so /opt/maple/libchdb.so; \
    chmod 0755 /opt/maple/maple

# ---

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --uid 10001 maple

# maple resolves libchdb.so relative to its own binary, so the two must stay in
# the same directory. MAPLE_LIBCHDB makes that explicit rather than implied.
COPY --from=fetch /opt/maple /opt/maple
RUN ln -s /opt/maple/maple /usr/local/bin/maple

ENV MAPLE_LIBCHDB=/opt/maple/libchdb.so \
    MAPLE_NO_UPDATE_CHECK=1 \
    MAPLE_LOCAL_BIND_HOST=0.0.0.0

# The data dir is a *subdirectory* of the volume on purpose: maple places its
# maintenance lock as a sibling of the data dir (`<data-dir>.maple-maintenance-lock`),
# so the parent has to be writable too. Pointing --data-dir straight at the
# volume root puts that lock in /var/lib, which is root-owned, and startup dies
# with EACCES.
RUN mkdir -p /var/lib/maple/data && chown -R maple:maple /var/lib/maple
VOLUME ["/var/lib/maple"]

USER maple
EXPOSE 4318

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:4318/health || exit 1

# --offline serves the UI bundled in the binary from this container. Without it
# maple points browsers at the hosted local.maple.dev dashboard, which talks to
# the *browser machine's* loopback and so can never reach a remote container.
CMD ["maple", "start", "--offline", "--host", "0.0.0.0", "--port", "4318", "--data-dir", "/var/lib/maple/data"]
