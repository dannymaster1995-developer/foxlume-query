#!/bin/bash
# Scratch PostgreSQL and MySQL servers for the TLS certificate tests (custom CA, client certificates).
# They run next to the regular test servers from dbtest.sh, on their own ports and data folders, and never touch them.
# Uses the server binaries in the .dbtest folder next to the repository (override with FOXLUME_DBTEST_DIR) and the
# certificates from scripts/tls-test-certs.sh (generated on first start). Servers listen on 127.0.0.1 only.
#
#   scripts/dbtest-tls.sh start|stop|status|reset
#
# PostgreSQL: 127.0.0.1:55442  data .dbtest/pg-tls-data
#             user postgres / postgres (scram-sha-256)
#             user certuser: client certificate only (pg_hba "cert", CN must be certuser), over TLS
# MySQL:      127.0.0.1:53316  data .dbtest/mysql-tls-data
#             user root / root (caching_sha2_password)
#             user certuser / certpass, REQUIRE X509 (a client certificate signed by the test CA)
# Both: server certificate for "localhost" signed by the test CA, which is also ssl_ca for client certificates.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
T="${FOXLUME_DBTEST_DIR:-$(cd "$SCRIPTS/../.." && pwd)/.dbtest}"
PG="$T/pg-bin/bin"
MY="$T/mysql-bin"
PGDATA="$T/pg-tls-data"
MYDATA="$T/mysql-tls-data"
CERTS="${FOXLUME_TLS_DIR:-$T/tls}"
RUN="$T/tls-run"
mkdir -p "$RUN"

certs() {
  [ -f "$CERTS/ca.crt" ] && [ -f "$CERTS/server.crt" ] && return
  FOXLUME_TLS_DIR="$CERTS" "$SCRIPTS/tls-test-certs.sh" >/dev/null
}

pg_init() {
  [ -d "$PGDATA" ] && return
  echo postgres > "$RUN/pgpass"
  "$PG/initdb" -D "$PGDATA" -U postgres --pwfile="$RUN/pgpass" --auth=scram-sha-256 -E UTF8 --locale=C >/dev/null
  rm -f "$RUN/pgpass"
  # Copies, so regenerating the certificates while the server runs cannot break it; the key must be 0600.
  cp "$CERTS/server.crt" "$CERTS/server.key" "$CERTS/ca.crt" "$PGDATA/"
  chmod 600 "$PGDATA/server.key"
  cat >> "$PGDATA/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = 55442
unix_socket_directories = '$RUN'
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
ssl_ca_file = 'ca.crt'
password_encryption = 'scram-sha-256'
EOF
  cat > "$PGDATA/pg_hba.conf" <<EOF
local all all scram-sha-256
hostssl all certuser 127.0.0.1/32 cert
host all certuser 127.0.0.1/32 reject
host all all 127.0.0.1/32 scram-sha-256
EOF
  "$PG/postgres" --single -j -D "$PGDATA" postgres >/dev/null <<'EOF'
CREATE ROLE certuser LOGIN;

EOF
}

pg_running() { "$PG/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }

my_init() {
  [ -d "$MYDATA" ] && return
  "$MY/bin/mysqld" --no-defaults --initialize-insecure --datadir="$MYDATA" --basedir="$MY" >/dev/null 2>&1
  mkdir -p "$MYDATA-certs"
  cp "$CERTS/server.crt" "$CERTS/server.key" "$CERTS/ca.crt" "$MYDATA-certs/"
}

my_ping() { "$MY/bin/mysqladmin" --no-defaults -S "$RUN/mysql.sock" -u root "$@" ping >/dev/null 2>&1; }
my_running() { my_ping -proot || my_ping; }

my_start() {
  "$MY/bin/mysqld" --no-defaults --datadir="$MYDATA" --basedir="$MY" \
    --bind-address=127.0.0.1 --port=53316 --mysqlx=OFF \
    --socket="$RUN/mysql.sock" --pid-file="$RUN/mysql.pid" \
    --log-error="$RUN/mysql.log" --secure-file-priv="$RUN" \
    --ssl-ca="$MYDATA-certs/ca.crt" --ssl-cert="$MYDATA-certs/server.crt" --ssl-key="$MYDATA-certs/server.key" \
    >/dev/null 2>&1 &
  for _ in $(seq 1 60); do
    my_running && return
    sleep 0.5
  done
  echo "MySQL did not start; see $RUN/mysql.log" >&2
  exit 1
}

my_seed() {
  [ -f "$MYDATA/.seeded" ] && return
  "$MY/bin/mysql" --no-defaults -S "$RUN/mysql.sock" -u root <<'EOF'
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'root';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED WITH caching_sha2_password BY 'root';
GRANT ALL ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'certuser'@'%' IDENTIFIED WITH caching_sha2_password BY 'certpass' REQUIRE X509;
FLUSH PRIVILEGES;
EOF
  touch "$MYDATA/.seeded"
}

case "${1:-status}" in
  start)
    certs
    pg_init
    pg_running || "$PG/pg_ctl" -D "$PGDATA" -l "$RUN/pg.log" -w start >/dev/null
    my_init
    my_running || my_start
    my_seed
    echo "TLS PostgreSQL on 127.0.0.1:55442, TLS MySQL on 127.0.0.1:53316 (certificates in $CERTS)"
    ;;
  stop)
    "$PG/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true
    "$MY/bin/mysqladmin" --no-defaults -S "$RUN/mysql.sock" -u root -proot shutdown >/dev/null 2>&1 || true
    echo stopped
    ;;
  status)
    pg_running && echo "postgres (TLS) is running" || echo "postgres (TLS): not running"
    my_running && echo "mysql (TLS) is running" || echo "mysql (TLS): not running"
    ;;
  reset)
    "$0" stop
    rm -rf "$PGDATA" "$MYDATA" "$MYDATA-certs" "$RUN"
    FOXLUME_TLS_DIR="$CERTS" "$SCRIPTS/tls-test-certs.sh" >/dev/null
    "$0" start
    ;;
esac
