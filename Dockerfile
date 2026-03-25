FROM postgres:17

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       postgresql-server-dev-17 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pgaudix
COPY . .

RUN make USE_PGXS=1 clean && make USE_PGXS=1 && make USE_PGXS=1 install
