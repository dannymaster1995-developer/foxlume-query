#!/bin/bash
# One PostgreSQL or MySQL server of a pinned version for the live tests: what each job of the server
# matrix workflow (.github/workflows/server-matrix.yml) runs, and a way to check one version on a Mac by hand.
# Versions, download URLs and SHA-256 checksums are pinned in scripts/server-matrix.json; every download is checked
# against its checksum. Downloads, binaries, data and logs go to .build/servers (override with FQ_SERVERS_DIR).
# The server listens where the live tests look, 127.0.0.1:55432 (PostgreSQL) or 127.0.0.1:53306 (MySQL), with the
# same users and seed data as scripts/dbtest.sh, so stop the local test servers first.
#
#   scripts/ci-server.sh fetch|start|test|stop <engine> <major>    engine: postgresql or mysql
#   scripts/ci-server.sh matrix [all | <engine>-<major>]            the workflow's job list as JSON
#   scripts/ci-server.sh suites <engine>                            the fqtest --filter for an engine's live suites
#   scripts/ci-server.sh clean [--all]                              delete data and logs (--all: downloads and builds too)
#
# PostgreSQL comes from the zonky embedded-postgres archives (server only), with pg_dump, pg_restore and psql from
# EDB's macOS binaries for the backup tests. MySQL comes from Oracle's macOS tarballs. Only prebuilt archives are
# used; nothing is compiled. `test` passes extra arguments on to fqtest.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPTS/.." && pwd)"
MANIFEST="$SCRIPTS/server-matrix.json"
ROOT="${FQ_SERVERS_DIR:-$REPO/.build/servers}"
DOWNLOADS="$ROOT/downloads"
RUN="$ROOT/run"
PG_PORT=55432
MY_PORT=53306

die() { echo "ci-server: $*" >&2; exit 1; }

usage() { sed -n '9,12p' "$0" | sed 's/^# //' >&2; exit 2; }

# The manifest entry of a server, or of the PostgreSQL client tools (pg-client).
entry() {
  if [ "$1" = pg-client ]; then
    jq -ce '.pg_client' "$MANIFEST"
  else
    jq -ce --arg e "$1" --arg m "$2" '.servers[] | select(.engine == $e and .major == $m)' "$MANIFEST" \
      || die "no $1 $2 in $MANIFEST"
  fi
}

field() { jq -r ".$2" <<<"$1"; }

# Downloads an entry's archive (trying its URLs in order) unless a verified copy is there; prints its path.
download() {
  local json="$1" sha file url actual
  sha="$(field "$json" sha256)"
  file="$DOWNLOADS/$(field "$json" 'urls[0]' | sed 's|.*/||')"
  mkdir -p "$DOWNLOADS"
  if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
    echo "$file"
    return
  fi
  rm -f "$file" "$file.part"
  for url in $(field "$json" 'urls[]'); do
    echo "Downloading $url" >&2
    curl -fsSL --retry 3 --retry-all-errors -o "$file.part" "$url" && break
    rm -f "$file.part"
  done
  [ -f "$file.part" ] || die "could not download $(field "$json" 'urls[0]')"
  actual="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
  if [ "$actual" != "$sha" ]; then
    rm -f "$file.part"
    die "checksum mismatch for $(basename "$file"): expected $sha, got $actual"
  fi
  mv "$file.part" "$file"
  echo "$file"
}

# Fails when a binary links a library outside macOS or its own folder (for example from Homebrew), which would make
# a cached server depend on what else the machine has installed.
check_links() {
  local foreign
  # Library lines start with a tab; the others name the file (and, in a universal binary, each architecture).
  foreign="$(otool -L "$@" | awk '/^\t/ && $1 !~ /^(\/usr\/lib\/|\/System\/|@)/ {print $1}' | sort -u)"
  [ -z "$foreign" ] || die "$(basename "$1") links libraries outside macOS: $foreign"
}

install_postgresql() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  # The jar holds one archive, postgres-darwin-arm_64.txz, with bin/, lib/ and share/.
  unzip -p "$archive" postgres-darwin-arm_64.txz | tar xJf - -C "$dest"
}

# Deletes the libraries in $1/lib that no program in $1/bin loads, directly or through another library (@rpath).
trim_libraries() {
  local dir="$1" keep="" changed=1 name file
  while [ "$changed" -eq 1 ]; do
    changed=0
    for name in $(otool -L "$dir"/bin/* $(for name in $keep; do echo "$dir/lib/$name"; done) 2>/dev/null \
        | awk '$1 ~ /^@rpath\// {sub("@rpath/", "", $1); print $1}' | sort -u); do
      case " $keep " in *" $name "*) ;; *) keep="$keep $name"; changed=1 ;; esac
    done
  done
  [ -n "$keep" ] || die "found no libraries the programs in $dir/bin load"
  for file in "$dir"/lib/*; do
    name="$(basename "$file")"
    case " $keep " in *" $name "*) ;; *) rm -rf "$file" ;; esac
  done
}

install_mysql() {
  local archive="$1" dest="$2" file
  mkdir -p "$dest"
  tar xzf "$archive" -C "$dest" --strip-components 1
  # Keep the server, the client tools the seed and the backup tests use, and the libraries they load.
  for file in "$dest"/bin/*; do
    case "$(basename "$file")" in mysqld|mysql|mysqladmin|mysqldump|*.dylib) ;; *) rm -f "$file" ;; esac
  done
  rm -rf "$dest/lib/mecab" "$dest/lib/plugin/debug" "$dest"/lib/*.a "$dest/mysql-test" "$dest/man" "$dest/docs" "$dest/include"
}

install_pg_client() {
  local archive="$1" dest="$2" tmp="$ROOT/build/pg-client"
  rm -rf "$tmp"
  mkdir -p "$tmp" "$dest"
  unzip -q "$archive" 'pgsql/bin/pg_dump' 'pgsql/bin/pg_restore' 'pgsql/bin/psql' 'pgsql/lib/*.dylib' -d "$tmp"
  rm -rf "$tmp/pgsql/lib/postgresql"
  mv "$tmp/pgsql/bin" "$tmp/pgsql/lib" "$dest/"
  rm -rf "$tmp"
  trim_libraries "$dest"
}

# Puts one server (or the PostgreSQL client tools) in $ROOT/dist/<name>, once per pinned version.
fetch() {
  local engine="$1" major="${2:-}" json name dest version archive
  json="$(entry "$engine" "$major")"
  version="$(field "$json" version)"
  name="$engine${major:+-$major}"
  dest="$ROOT/dist/$name"
  [ "$(cat "$dest/.version" 2>/dev/null)" = "$version" ] && return
  rm -rf "$dest"
  archive="$(download "$json")"
  case "$engine" in
    postgresql) install_postgresql "$archive" "$dest"; check_links "$dest/bin/postgres" ;;
    mysql) install_mysql "$archive" "$dest" ;;
    pg-client) install_pg_client "$archive" "$dest" ;;
  esac
  echo "$version" > "$dest/.version"
  echo "$name $version in $dest" >&2
}

# Sets the variables scripts/test-servers.sh works with.
server_env() {
  local engine="$1" major="$2" data="$ROOT/data/$1-$2"
  mkdir -p "$RUN"
  # macOS limits a Unix socket path to 103 characters; the longest one here is $RUN/.s.PGSQL.55432.
  [ ${#RUN} -le 88 ] || die "socket folder $RUN is too long; set FQ_SERVERS_DIR to a shorter path"
  case "$engine" in
    postgresql) PG="$ROOT/dist/$engine-$major/bin"; PGDATA="$data/pg" ;;
    mysql) MY="$ROOT/dist/$engine-$major"; MYDATA="$data/mysql" ;;
    *) usage ;;
  esac
  mkdir -p "$data"
  source "$SCRIPTS/test-servers.sh"
}

port_free() { ! nc -z 127.0.0.1 "$1" 2>/dev/null; }

start() {
  local engine="$1" major="$2"
  fetch "$engine" "$major"
  server_env "$engine" "$major"
  case "$engine" in
    postgresql)
      "$PG/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 && return
      port_free "$PG_PORT" || die "port $PG_PORT is in use; stop the other server first (scripts/dbtest.sh stop)"
      pg_init
      pg_seed
      grep -qi error "$RUN/pg-seed.log" && { cat "$RUN/pg-seed.log" >&2; die "the PostgreSQL seed failed"; }
      pg_start
      echo "$("$PG/postgres" --version) on 127.0.0.1:$PG_PORT"
      ;;
    mysql)
      my_ping -u root -proot && return
      port_free "$MY_PORT" || die "port $MY_PORT is in use; stop the other server first (scripts/dbtest.sh stop)"
      my_init
      my_start
      my_seed
      [ "$("$MY/bin/mysql" --no-defaults -S "$RUN/mysql.sock" -u root -proot -N -e 'SELECT COUNT(*) FROM foxlume.perf_big' 2>/dev/null)" = 2000000 ] \
        || die "the seed did not create foxlume.perf_big"
      echo "MySQL $(my_version) on 127.0.0.1:$MY_PORT"
      ;;
  esac
}

stop() {
  server_env "$1" "$2"
  case "$1" in
    postgresql) "$PG/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true ;;
    *) "$MY/bin/mysqladmin" --no-defaults -S "$RUN/mysql.sock" -u root -proot shutdown >/dev/null 2>&1 || true ;;
  esac
  echo stopped
}

# Every test type in the files that use the engine's test server. Other engines' suites in those files skip
# themselves, so new live suites are picked up without a list to maintain.
suites() {
  local marker
  case "$1" in
    postgresql) marker='PostgresTestServer|LiveServer\.postgres' ;;
    mysql) marker='MySQLTestServer|LiveServer\.mysql' ;;
    *) usage ;;
  esac
  grep -rlE "$marker" "$REPO/Tests" \
    | xargs grep -hoE '^[[:space:]]*(@Suite[^{]*[[:space:]])?(final )?(struct|class) [A-Za-z0-9_]+Tests\b' \
    | awk '{print $NF}' | sort -u | paste -sd '|' -
}

run_tests() {
  local engine="$1" major="$2" log status=0
  shift 2
  [ "$engine" = postgresql ] && fetch pg-client
  mkdir -p "$ROOT/logs"
  log="$ROOT/logs/$engine-$major.log"
  source "$REPO/scripts/env.sh"
  # The backup tests use these client tools: pg_dump 18 for every PostgreSQL version, the server's own for MySQL.
  if [ "$engine" = postgresql ]; then
    export FQ_PG_CLIENT_BIN="$ROOT/dist/pg-client/bin"
  else
    export FQ_MYSQL_CLIENT_BIN="$ROOT/dist/$engine-$major/bin"
  fi
  fqtest --no-parallel --filter "($(suites "$engine"))" "$@" 2>&1 | tee "$log" || status=$?
  # A run that stops early can still exit 0, so it must reach Swift Testing's summary line.
  if ! grep -q 'Test run with [0-9]* test' "$log"; then
    echo "::error::$engine $major: the test run ended before its summary"
    status=1
  fi
  if [ "$status" -ne 0 ]; then
    echo
    echo "==== Failures on $engine $major ($(grep -m1 'Test run with' "$log" || echo 'no summary')) ===="
    grep -E -A4 '✘|error:|fatal error|Fatal error' "$log" | grep -v '^--$' | head -300 || true
  fi
  return "$status"
}

matrix() {
  jq -ce --arg pick "${1:-all}" '{include: [.servers[]
      | select($pick == "all" or $pick == "" or $pick == (.engine + "-" + .major))
      | {engine, major, version}]}
    | if (.include | length) == 0 then error("no server matches \($pick)") else . end' "$MANIFEST"
}

clean() {
  if [ "${1:-}" = --all ]; then
    rm -rf "$ROOT"
  else
    rm -rf "$ROOT/data" "$ROOT/run" "$ROOT/logs" "$ROOT/build"
  fi
}

command -v jq >/dev/null || die "needs jq (macOS 15 and later include it)"
case "${1:-}" in
  fetch) [ $# -eq 3 ] || usage; fetch "$2" "$3"; [ "$2" != postgresql ] || fetch pg-client ;;
  start) [ $# -eq 3 ] || usage; start "$2" "$3" ;;
  stop) [ $# -eq 3 ] || usage; stop "$2" "$3" ;;
  test) [ $# -ge 3 ] || usage; shift; run_tests "$@" ;;
  matrix) matrix "${2:-all}" ;;
  suites) [ $# -eq 2 ] || usage; suites "$2" ;;
  clean) clean "${2:-}" ;;
  *) usage ;;
esac
