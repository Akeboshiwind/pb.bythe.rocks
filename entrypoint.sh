#!/bin/sh
set -e

DATA_DIR="${PB_DATA_DIR:-/pb_data}"
DB_PATH="${DATA_DIR}/data.db"
HTTP_ADDR="${PB_HTTP_ADDR:-0.0.0.0:8080}"

mkdir -p "${DATA_DIR}"

litestream_configured() {
    [ -n "${LITESTREAM_BUCKET}" ] \
        && [ -n "${LITESTREAM_ENDPOINT}" ] \
        && [ -n "${LITESTREAM_ACCESS_KEY_ID}" ] \
        && [ -n "${LITESTREAM_SECRET_ACCESS_KEY}" ]
}

if litestream_configured; then
    echo "[entrypoint] Litestream configured (bucket=${LITESTREAM_BUCKET})."

    if [ ! -f "${DB_PATH}" ]; then
        echo "[entrypoint] No local DB found. Attempting restore from replica..."
        litestream restore -if-replica-exists -config /etc/litestream.yml "${DB_PATH}" \
            || echo "[entrypoint] No replica to restore from. Will start fresh."
    else
        echo "[entrypoint] Existing local DB found at ${DB_PATH}. Skipping restore."
    fi

    echo "[entrypoint] Starting PocketBase under Litestream..."
    exec litestream replicate -config /etc/litestream.yml \
        -exec "pocketbase serve --http=${HTTP_ADDR} --dir=${DATA_DIR}"
else
    echo "[entrypoint] Litestream not configured (missing one of LITESTREAM_BUCKET, LITESTREAM_ENDPOINT, LITESTREAM_ACCESS_KEY_ID, LITESTREAM_SECRET_ACCESS_KEY). Starting PocketBase without backups."
    exec pocketbase serve --http="${HTTP_ADDR}" --dir="${DATA_DIR}"
fi
