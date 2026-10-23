#!/bin/bash
# Local PostgreSQL, MySQL, MongoDB and Redis servers for the live driver tests (they skip when a port is closed).
# Expects prebuilt server binaries in a .dbtest folder next to the repository (override with FOXLUME_DBTEST_DIR);
# data, sockets and logs live there too. Servers listen on 127.0.0.1 only.
#
#   scripts/dbtest.sh start|stop|status|reset
#
# PostgreSQL: 127.0.0.1:55432  user postgres / password postgres (scram-sha-256), db foxlume
#             user md5user / md5pass (md5)
# MySQL:      127.0.0.1:53306  user root / root (caching_sha2_password), db foxlume
#             user native / nativepass (mysql_native_password)
#             user fqauth / fqauthpass (created by the authentication-path tests in MySQLTests.swift)
# MongoDB:    127.0.0.1:57017  auth enabled, TLS allowed (self-signed); users are created by the driver's seed step
# Redis:      127.0.0.1:56379  default password redispass, ACL user easy / easypass
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
T="${FOXLUME_DBTEST_DIR:-$(cd "$SCRIPTS/../.." && pwd)/.dbtest}"
PG="$T/pg-bin/bin"
MY="$T/mysql-bin"
PGDATA="$T/pg-data"
MYDATA="$T/mysql-data"
MONGO="$T/mongo-bin/bin"
MONGODATA="$T/mongo-data"
REDIS="$T/redis-src/src"
REDISDATA="$T/redis-data"
RUN="$T/run"
PG_PORT=55432
MY_PORT=53306
mkdir -p "$RUN"

source "$SCRIPTS/test-servers.sh"

mongo_start() {
  mkdir -p "$MONGODATA"
  if [ ! -f "$RUN/mongo.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$RUN/mongo.key" -out "$RUN/mongo.crt" \
      -subj "/CN=localhost" -days 3650 >/dev/null 2>&1
    cat "$RUN/mongo.key" "$RUN/mongo.crt" > "$RUN/mongo.pem"
  fi
  "$MONGO/mongod" --dbpath "$MONGODATA" --bind_ip 127.0.0.1 --port 57017 --auth \
    --tlsMode allowTLS --tlsCertificateKeyFile "$RUN/mongo.pem" --tlsCAFile "$RUN/mongo.crt" --tlsAllowConnectionsWithoutCertificates \
    --unixSocketPrefix "$RUN" --pidfilepath "$RUN/mongo.pid" --logpath "$RUN/mongo.log" >/dev/null 2>&1 &
  # mongod cannot --fork on macOS, so wait for its port instead.
  for _ in $(seq 1 60); do
    nc -z 127.0.0.1 57017 2>/dev/null && return
    sleep 0.25
  done
  echo "MongoDB did not start; see $RUN/mongo.log" >&2
  exit 1
}

mongo_running() { [ -f "$RUN/mongo.pid" ] && kill -0 "$(cat "$RUN/mongo.pid")" 2>/dev/null; }

redis_start() {
  mkdir -p "$REDISDATA"
  cat > "$RUN/redis.conf" <<EOF
port 56379
bind 127.0.0.1
protected-mode yes
dir $REDISDATA
pidfile $RUN/redis.pid
logfile $RUN/redis.log
daemonize yes
save ""
appendonly no
requirepass redispass
user easy on >easypass ~* &* +@all
EOF
  "$REDIS/redis-server" "$RUN/redis.conf"
  for _ in $(seq 1 30); do
    "$REDIS/redis-cli" -p 56379 -a redispass --no-auth-warning ping >/dev/null 2>&1 && break
    sleep 0.2
  done
  # Redis keeps nothing on disk (save "", no AOF), so seed on every start; the seed begins with FLUSHALL.
  "$REDIS/redis-cli" -p 56379 -a redispass --no-auth-warning < "$SCRIPTS/seed-redis.txt" >/dev/null
}

redis_running() { "$REDIS/redis-cli" -p 56379 -a redispass --no-auth-warning ping >/dev/null 2>&1; }

case "${1:-status}" in
  start)
    pg_init
    pg_seed
    pg_start
    my_init
    "$MY/bin/mysqladmin" --no-defaults -S "$RUN/mysql.sock" -u root -proot ping >/dev/null 2>&1 || my_start
    my_seed
    mongo_running || mongo_start
    redis_running || redis_start
    echo "PostgreSQL on 127.0.0.1:55432, MySQL on 127.0.0.1:53306, MongoDB on 127.0.0.1:57017, Redis on 127.0.0.1:56379"
    ;;
  stop)
    "$PG/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true
    "$MY/bin/mysqladmin" --no-defaults -S "$RUN/mysql.sock" -u root -proot shutdown >/dev/null 2>&1 || true
    mongo_running && kill "$(cat "$RUN/mongo.pid")"
    "$REDIS/redis-cli" -p 56379 -a redispass --no-auth-warning shutdown nosave >/dev/null 2>&1 || true
    echo stopped
    ;;
  status)
    "$PG/pg_ctl" -D "$PGDATA" status 2>/dev/null | head -1 || echo "postgres: not running"
    "$MY/bin/mysqladmin" --no-defaults -S "$RUN/mysql.sock" -u root -proot ping 2>/dev/null || echo "mysql: not running"
    mongo_running && echo "mongod is running" || echo "mongodb: not running"
    redis_running && echo "redis is running" || echo "redis: not running"
    ;;
  reset)
    "$0" stop
    rm -rf "$PGDATA" "$MYDATA" "$MONGODATA" "$REDISDATA" "$RUN"
    "$0" start
    ;;
esac
