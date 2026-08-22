#!/usr/bin/env bash
# All-in-one Buzz relay entrypoint:
#   1. start Postgres (initdb + start + create db/user)
#   2. start Redis (requirepass)
#   3. start MinIO (S3) + create bucket
#   4. wait for all deps healthy
#   5. run DB migrations
#   6. exec the relay in the foreground
set -euo pipefail

export PATH="/usr/lib/postgresql/$(ls /usr/lib/postgresql | head -1)/bin:$PATH"

PGDATA=/var/lib/postgresql/data
PGPASSWORD="${POSTGRES_PASSWORD}"
BUZZ_USER="${POSTGRES_USER:-buzz}"
BUZZ_DB="${POSTGRES_DB:-buzz}"

echo "[entrypoint] starting Postgres..."
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  su postgres -c "/usr/lib/postgresql/$(ls /usr/lib/postgresql | head -1)/bin/initdb -D $PGDATA -A trust" >/tmp/pg-init.log 2>&1
fi
su postgres -c "/usr/lib/postgresql/$(ls /usr/lib/postgresql | head -1)/bin/pg_ctl -D $PGDATA -l /tmp/pg.log -o '-c listen_addresses=localhost -p 5432' start"

echo "[entrypoint] waiting for Postgres..."
for i in $(seq 1 60); do
  if su postgres -c "pg_isready -h localhost -p 5432" >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "[entrypoint] creating role/db if missing..."
su postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='$BUZZ_USER'\" | grep -q 1 || psql -c \"CREATE USER $BUZZ_USER WITH PASSWORD '$PGPASSWORD' SUPERUSER;\""
su postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='$BUZZ_DB'\" | grep -q 1 || psql -c \"CREATE DATABASE $BUZZ_DB OWNER $BUZZ_USER;\""

echo "[entrypoint] starting Redis..."
redis-server --requirepass "$REDIS_PASSWORD" --daemonize yes --save "" --appendonly no >/tmp/redis.log 2>&1
for i in $(seq 1 30); do
  if redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then break; fi
  sleep 1
done

echo "[entrypoint] starting MinIO (S3)..."
mkdir -p /data/minio
export MINIO_ROOT_USER="$BUZZ_S3_ACCESS_KEY"
export MINIO_ROOT_PASSWORD="$BUZZ_S3_SECRET_KEY"
nohup minio server /data/minio --address 127.0.0.1:9000 --console-address 127.0.0.1:9001 >/tmp/minio.log 2>&1 &
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then break; fi
  sleep 1
done
mc alias set local http://127.0.0.1:9000 "$BUZZ_S3_ACCESS_KEY" "$BUZZ_S3_SECRET_KEY" >/dev/null 2>&1
mc mb --ignore-existing "local/$BUZZ_S3_BUCKET" >/dev/null 2>&1
mc anonymous set none "local/$BUZZ_S3_BUCKET" >/dev/null 2>&1

echo "[entrypoint] running DB migrations..."
BUZZ_AUTO_MIGRATE=true buzz-admin migrate >/tmp/migrate.log 2>&1 || echo "[entrypoint] migrate returned non-zero (relay will retry on boot)"

echo "[entrypoint] launching relay..."
exec buzz-relay
