

ARG PG_TAG=18.6
FROM postgres:${PG_TAG}


RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential postgresql-server-dev-${PG_MAJOR}=${PG_VERSION} \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/ttree
COPY Makefile ttree.control ./
COPY src ./src
COPY sql ./sql


ARG TT_MAX_KEYS=4
RUN make PG_CPPFLAGS="-DTT_MAX_KEYS=${TT_MAX_KEYS}" && make install

COPY docker/initdb/ /docker-entrypoint-initdb.d/
