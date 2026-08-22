#!/usr/bin/env bash
# All-in-one Buzz relay entrypoint (diagnostic-friendly version).
# Every step is logged to /tmp/entrypoint.log and echoed, so a silent
# crash still leaves a trace. `set -e` is intentionally NOT used: we log
# and continue, only the final relay exec must succeed.
exec > /tmp/entrypoint.log 2>&1
set -x

echo "[entrypoint] === starting at $(date -u) ==="
echo "[entrypoint] PATH before: $PATH"

# Locate postgres binaries
PGDIR="/usr/lib/postgresql/$(ls /usr/lib/postgresql 2>/dev/null | head -1)"
export PATH="$PGDIR/bin:$PATH"
echo "[entrypoint] postgres dir: $PGDIR"

PGDATA=/var/lib/postgresql/data
PGPASSWORD="${POSTGRES_PASSWORD:-buzzpass}"
BUZZ_USER="${POSTGRES_USER:-buzz}"
BUZZ_DB="${POSTGRES_DB:-buzz}"

echo "[entrypoint] starting Postgres..."
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "[entrypoint] initdb..."
  su postgres -c "$PGDIR/bin/initdb -D $PGDATA -A trust" 2>&1 | tail -5
fi
su postgres -c "$PGDIR/bin/pg_ctl -D $PGDATA -l /tmp/pg.log -o '-c listen_addresses=localhost -p 5432' start" 2>&1 | tail -5

echo "[entrypoint] waiting for Postgres..."
for i in $(seq 1 60); do
  if su postgres -c "pg_isready -h localhost -p 5432" >/dev/null 2>&1; then echo "[entrypoint] Postgres ready"; break; fi
  sleep 1
done
su postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='$BUZZ_USER'\" | grep -q 1 || psql -c \"CREATE USER $BUZZ_USER WITH PASSWORD '$PGPASSWORD' SUPERUSER;\""
su postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='$BUZZ_DB'\" | grep -q 1 || psql -c \"CREATE DATABASE $BUZZ_DB OWNER $BUZZ_USER;\""
echo "[entrypoint] Postgres role/db ready"

echo "[entrypoint] starting Redis..."
redis-server --requirepass "$REDIS_PASSWORD" --daemonize yes --save "" --appendonly no 2>&1 | tail -3
for i in $(seq 1 30); do
  if redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then echo "[entrypoint] Redis ready"; break; fi
  sleep 1
done

echo "[entrypoint] starting MinIO (S3)..."
mkdir -p /data/minio
export MINIO_ROOT_USER="$BUZZ_S3_ACCESS_KEY"
export MINIO_ROOT_PASSWORD="$BUZZ_S3_SECRET_KEY"
nohup minio server /data/minio --address 127.0.0.1:9000 --console-address 127.0.0.1:9001 >/tmp/minio.log 2>&1 &
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then echo "[entrypoint] MinIO ready"; break; fi
  sleep 1
done
mc alias set local http://127.0.0.1:9000 "$BUZZ_S3_ACCESS_KEY" "$BUZZ_S3_SECRET_KEY" 2>&1 | tail -2
mc mb --ignore-existing "local/$BUZZ_S3_BUCKET" 2>&1 | tail -2
mc anonymous set none "local/$BUZZ_S3_BUCKET" 2>&1 | tail -2

echo "[entrypoint] running DB migrations..."
BUZZ_AUTO_MIGRATE=true buzz-admin migrate 2>&1 | tail -10 || echo "[entrypoint] migrate returned non-zero (relay will retry on boot)"

echo "[entrypoint] launching relay in foreground..."
exec buzz-relay
