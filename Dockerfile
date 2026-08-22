# All-in-one Buzz relay: relay + Postgres + Redis + MinIO in ONE container.
# Base image already ships the compiled relay binary (no Rust build needed).
FROM ghcr.io/block/buzz:main

USER root

# Postgres + Redis from apt; MinIO + mc as static binaries.
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql postgresql-contrib redis-server \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/local/bin/minio \
    && chmod +x /usr/local/bin/minio \
    && curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /var/lib/postgresql/data /data/minio /data/git \
    && chown -R postgres:postgres /var/lib/postgresql

# ---- Relay configuration (stable secrets — do NOT rotate) ----
ENV BUZZ_BIND_ADDR=0.0.0.0:3000 \
    BUZZ_HEALTH_PORT="8080" \
    BUZZ_METRICS_PORT="9102" \
    BUZZ_GIT_REPO_PATH=/data/git \
    BUZZ_AUTO_MIGRATE="true" \
    BUZZ_GIT_CONFORMANCE_PROBE="true" \
    BUZZ_REQUIRE_AUTH_TOKEN="true" \
    BUZZ_REQUIRE_RELAY_MEMBERSHIP="true" \
    BUZZ_ALLOW_NIP_OA_AUTH="true" \
    BUZZ_DOMAIN=buzz.local \
    RELAY_URL=ws://buzz.local:3000 \
    BUZZ_MEDIA_BASE_URL=http://buzz.local:3000/media \
    BUZZ_MEDIA_SERVER_DOMAIN=buzz.local \
    BUZZ_CORS_ORIGINS="*" \
    RUST_LOG=buzz_relay=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info,tower_http=info \
    POSTGRES_USER=buzz \
    POSTGRES_DB=buzz \
    POSTGRES_PASSWORD=3ysmp9-ge3Z4Q3RHDPCwTk30 \
    REDIS_PASSWORD=UuNy7kGvCUSvm18GDD-hHXCf \
    BUZZ_S3_ACCESS_KEY=49aFFu8YHqdEg7QY \
    BUZZ_S3_SECRET_KEY=A3Ix4TXZJWo_NNYh8zmoWOcc8EXUu7tz \
    BUZZ_S3_BUCKET=buzz-media \
    BUZZ_S3_ADDRESSING_STYLE=path \
    BUZZ_S3_ENDPOINT=http://127.0.0.1:9000 \
    DATABASE_URL=postgres://buzz:3ysmp9-ge3Z4Q3RHDPCwTk30@127.0.0.1:5432/buzz \
    REDIS_URL=redis://:UuNy7kGvCUSvm18GDD-hHXCf@127.0.0.1:6379 \
    RELAY_OWNER_PUBKEY=7aaca401042cab2ace13b62777907a92cd4016544a071ffebd9ad1c47e7885a9 \
    BUZZ_RELAY_PRIVATE_KEY=9fd1e864bd5e336de58d2f27319078ed5f95746daa6645e5584bd1c2312f59e1 \
    BUZZ_GIT_HOOK_HMAC_SECRET=1200f4ba8311f529c37a4f7c146de2b0ebf69705064a8bf159bdd3323882c1c7

EXPOSE 3000 8080 9102

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
