# CI image: PostgreSQL built from source (distro packages don't ship the
# PostgreSQL::Test perl modules needed by the TAP suite), extension built
# and installed on top. The container's default command runs the tests.
#
#   docker build -f ci/Dockerfile --build-arg PG_VERSION=17.5 -t pg_ddl_repl-ci .
#   docker run --rm pg_ddl_repl-ci
FROM debian:bookworm-slim

ARG PG_VERSION=17.5

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential flex bison \
        libreadline-dev zlib1g-dev libicu-dev pkg-config \
        perl libipc-run-perl \
        curl ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# --enable-cassert: assertion-checked build, catches C-level bugs in the
# deparse code that a production build would let slide.
# The two extra install steps put pg_regress and the PostgreSQL::Test perl
# modules into the install tree's pgxs directory -- that is where a PGXS
# TAP_TESTS installcheck resolves them from, letting us drop the source tree.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz" \
        | tar -xz -C /usr/src \
    && cd "/usr/src/postgresql-${PG_VERSION}" \
    && ./configure --prefix=/usr/local/pgsql --enable-tap-tests --enable-debug --enable-cassert \
    && make -j"$(nproc)" \
    && make install \
    && make -C src/test/regress install \
    && make -C src/test/perl install \
    && cd / && rm -rf "/usr/src/postgresql-${PG_VERSION}"

ENV PATH=/usr/local/pgsql/bin:$PATH

# The TAP clusters run initdb, which refuses to run as root.
RUN useradd --create-home postgres

WORKDIR /workspace
COPY --chown=postgres:postgres . .

# chown the directory itself too: COPY --chown leaves it root-owned and installcheck writes tmp_check/ there.
RUN make && make install && chown postgres:postgres /workspace

USER postgres
CMD ["sh", "ci/run-tests.sh"]
