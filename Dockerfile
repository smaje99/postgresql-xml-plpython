FROM postgres:18.6-bookworm

USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        postgresql-plpython3-18 \
        python3-lxml \
    && rm -rf /var/lib/apt/lists/*

USER postgres
