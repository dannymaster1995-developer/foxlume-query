# Shared steps for the PostgreSQL and MySQL test servers: data folder set-up, start and seed.
# Sourced by scripts/dbtest.sh (the local servers) and scripts/ci-server.sh (one pinned version, as the server matrix
# workflow runs it). The caller sets:
#   SCRIPTS   the scripts folder (seed files)
#   RUN       folder for sockets, pid files, logs and the initdb password file
#   PG PGDATA PG_PORT        PostgreSQL bin folder, data folder and port
#   MY MYDATA MY_PORT        MySQL base folder (with bin/), data folder and port
# Works on PostgreSQL 13 and later and MySQL 8.0 and later.

pg_init() {
  [ -d "$PGDATA" ] && return
  echo postgres > "$RUN/pgpass"
  "$PG/initdb" -D "$PGDATA" -U postgres --pwfile="$RUN/pgpass" --auth=scram-sha-256 -E UTF8 --locale=C >/dev/null
  cat >> "$PGDATA/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = $PG_PORT
unix_socket_directories = '$RUN'
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
password_encryption = 'scram-sha-256'
EOF
  openssl req -new -x509 -days 3650 -nodes -subj "/CN=localhost" \
    -keyout "$PGDATA/server.key" -out "$PGDATA/server.crt" >/dev/null 2>&1
  chmod 600 "$PGDATA/server.key"
  cat > "$PGDATA/pg_hba.conf" <<EOF
local all all scram-sha-256
host all md5user 127.0.0.1/32 md5
host all all 127.0.0.1/32 scram-sha-256
EOF
}

# Seed in single-user mode (the portable build ships no psql). Statements end with ";" + blank line (-j).
pg_seed() {
  [ -f "$PGDATA/.seeded" ] && return
  "$PG/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true
  "$PG/postgres" --single -j -D "$PGDATA" postgres >/dev/null <<'EOF'
SET password_encryption = 'md5';

CREATE ROLE md5user LOGIN PASSWORD 'md5pass';

CREATE DATABASE foxlume;

EOF
  awk '{print} /;[[:space:]]*$/ {print ""}' "$SCRIPTS/seed-postgres.sql" \
    | "$PG/postgres" --single -j -D "$PGDATA" foxlume > "$RUN/pg-seed.log" 2>&1
  touch "$PGDATA/.seeded"
}

pg_start() {
  "$PG/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 || "$PG/pg_ctl" -D "$PGDATA" -l "$RUN/pg.log" -w start >/dev/null
}

# "8.4.9", from the server binary.
my_version() { "$MY/bin/mysqld" --version 2>/dev/null | sed -E 's/.*Ver ([0-9.]+).*/\1/'; }

# True when the server is at or above major.minor ($1 $2).
my_at_least() {
  local version major minor
  version="$(my_version)"
  major="${version%%.*}"; minor="${version#*.}"; minor="${minor%%.*}"
  [ "$major" -gt "$1" ] || { [ "$major" -eq "$1" ] && [ "$minor" -ge "$2" ]; }
}

my_init() {
  [ -d "$MYDATA" ] && return
  "$MY/bin/mysqld" --no-defaults --initialize-insecure --datadir="$MYDATA" --basedir="$MY" >/dev/null 2>&1
}

my_ping() { "$MY/bin/mysqladmin" --no-defaults -S "$RUN/mysql.sock" "$@" ping >/dev/null 2>&1; }

my_start() {
  local extra=()
  # 8.4 turned mysql_native_password off by default; 8.0 always has it.
  my_at_least 8 4 && extra=(--mysql-native-password=ON)
  "$MY/bin/mysqld" --no-defaults --datadir="$MYDATA" --basedir="$MY" \
    --bind-address=127.0.0.1 --port="$MY_PORT" --mysqlx=OFF \
    --socket="$RUN/mysql.sock" --pid-file="$RUN/mysql.pid" \
    --log-error="$RUN/mysql.log" --secure-file-priv="$RUN" \
    ${extra[@]+"${extra[@]}"} >/dev/null 2>&1 &
  for _ in $(seq 1 60); do
    my_ping -u root && return
    my_ping -u root -proot && return
    sleep 0.5
  done
  echo "MySQL did not start; see $RUN/mysql.log" >&2
  exit 1
}

# Seeds once; later starts keep whatever the databases hold now (seed-mysql-orders.sql drops and recreates `orders`).
my_seed() {
  [ -f "$MYDATA/.seeded" ] && return
  local auth=(-u root)
  "$MY/bin/mysql" --no-defaults -S "$RUN/mysql.sock" -u root -e "SELECT 1" >/dev/null 2>&1 || auth=(-u root -proot)
  "$MY/bin/mysql" --no-defaults -S "$RUN/mysql.sock" "${auth[@]}" 2>/dev/null <<'EOF'
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'root';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED WITH caching_sha2_password BY 'root';
GRANT ALL ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'native'@'%' IDENTIFIED WITH mysql_native_password BY 'nativepass';
GRANT ALL ON *.* TO 'native'@'%';
CREATE DATABASE IF NOT EXISTS foxlume;
FLUSH PRIVILEGES;
EOF
  "$MY/bin/mysql" --no-defaults -S "$RUN/mysql.sock" -u root -proot foxlume < "$SCRIPTS/seed-mysql.sql" 2>/dev/null
  "$MY/bin/mysql" --no-defaults -S "$RUN/mysql.sock" -u root -proot < "$SCRIPTS/seed-mysql-orders.sql" 2>/dev/null
  touch "$MYDATA/.seeded"
}
