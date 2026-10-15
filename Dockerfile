FROM postgres:16

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-psycopg2 \
    curl \
    && pip3 install --break-system-packages patroni[etcd3] \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/lib/postgresql/patroni \
    && chown -R postgres:postgres /var/lib/postgresql/patroni \
    && chmod 700 /var/lib/postgresql/patroni

USER postgres