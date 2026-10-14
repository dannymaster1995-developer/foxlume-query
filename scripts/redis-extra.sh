#!/bin/bash
# Extra Redis processes for the Sentinel and Cluster driver tests. The main test server (dbtest.sh, port 56379)
# is not touched. Data, config, logs and pid files live in .dbtest/redis-extra next to the repository (override the
# .dbtest location with FOXLUME_DBTEST_DIR); everything binds 127.0.0.1.
#
#   scripts/redis-extra.sh start|stop|status|reset
#
# Sentinel group "mymaster":  master 56380, replica 56381 (password redispass)
#                             sentinel 56382 (requirepass redispass, ACL user sentinel-admin / redispass)
# Cluster, 3 masters:         56390 56391 56392 (bus ports 56393-56395, password redispass)
# TLS proxy:                  56398 → master 56380. The Redis build has no TLS, so `openssl s_server` terminates TLS
#                             (self-signed cert for CN=localhost) and nc forwards to the master. It serves one client
#                             at a time over one shared Redis connection: enough for handshake tests, nothing more.
set -euo pipefail

DBTEST="${FOXLUME_DBTEST_DIR:-}"
if [ -z "$DBTEST" ]; then
  # The repository may be a working copy deeper in the tree; find the nearest folder that holds .dbtest.
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  while [ "$ROOT" != "/" ] && [ ! -d "$ROOT/.dbtest/redis-src" ]; do ROOT="$(dirname "$ROOT")"; done
  DBTEST="$ROOT/.dbtest"
fi
[ -d "$DBTEST/redis-src" ] || { echo "cannot find $DBTEST/redis-src" >&2; exit 1; }
BIN="$DBTEST/redis-src/src"
DIR="$DBTEST/redis-extra"
PASS=redispass
CLUSTER_PORTS=(56390 56391 56392)
CLI() { "$BIN/redis-cli" -h 127.0.0.1 -a "$PASS" --no-auth-warning "$@"; }

common() { # port
  cat <<EOF
port $1
bind 127.0.0.1
protected-mode yes
daemonize yes
dir $DIR/$1
pidfile $DIR/$1/redis.pid
logfile $DIR/$1/redis.log
save ""
appendonly no
requirepass $PASS
masterauth $PASS
EOF
}

wait_ping() { # port
  for _ in $(seq 1 50); do
    CLI -p "$1" ping >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "port $1 did not start" >&2
  return 1
}

running() { CLI -p "$1" ping >/dev/null 2>&1; }

start_node() { # port extra-config
  local port=$1
  running "$port" && return 0
  mkdir -p "$DIR/$port"
  { common "$port"; printf '%s\n' "${2:-}"; } > "$DIR/$port/redis.conf"
  "$BIN/redis-server" "$DIR/$port/redis.conf"
  wait_ping "$port"
}

start_sentinel() {
  running 56382 && return 0
  mkdir -p "$DIR/56382"
  # Sentinel rewrites its config file, so it is created only once.
  if [ ! -f "$DIR/56382/sentinel.conf" ]; then
    cat > "$DIR/56382/sentinel.conf" <<EOF
port 56382
bind 127.0.0.1
daemonize yes
dir $DIR/56382
pidfile $DIR/56382/sentinel.pid
logfile $DIR/56382/sentinel.log
requirepass $PASS
user sentinel-admin on >$PASS ~* &* +@all
sentinel monitor mymaster 127.0.0.1 56380 1
sentinel auth-pass mymaster $PASS
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
EOF
  fi
  "$BIN/redis-server" "$DIR/56382/sentinel.conf" --sentinel
  wait_ping 56382
}

start_cluster() {
  local index=0
  for port in "${CLUSTER_PORTS[@]}"; do
    start_node "$port" "cluster-enabled yes
cluster-config-file $DIR/$port/nodes.conf
cluster-node-timeout 5000
cluster-port $((56393 + index))"
    index=$((index + 1))
  done
  if ! CLI -p 56390 cluster info | grep -q "cluster_slots_assigned:16384"; then
    CLI --cluster create 127.0.0.1:56390 127.0.0.1:56391 127.0.0.1:56392 --cluster-replicas 0 --cluster-yes >"$DIR/cluster-create.log" 2>&1
  fi
  for _ in $(seq 1 100); do
    CLI -p 56390 cluster info | grep -q "cluster_state:ok" && return 0
    sleep 0.1
  done
  echo "cluster did not reach cluster_state:ok" >&2
  return 1
}

start_tls_proxy() {
  local tls="$DIR/tls"
  mkdir -p "$tls"
  if [ -f "$tls/proxy.pids" ] && kill -0 $(head -1 "$tls/proxy.pids") 2>/dev/null; then return 0; fi
  if [ ! -f "$tls/cert.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tls/key.pem" -out "$tls/cert.pem" -days 365 -subj "/CN=localhost" >/dev/null 2>&1
  fi
  rm -f "$tls/up" "$tls/down"
  mkfifo "$tls/up" "$tls/down"
  # Open order matters: each side opens its first FIFO for the direction the other side opens first.
  openssl s_server -quiet -accept 56398 -cert "$tls/cert.pem" -key "$tls/key.pem" < "$tls/down" > "$tls/up" 2>>"$tls/s_server.log" &
  local server=$!
  nc 127.0.0.1 56380 > "$tls/down" < "$tls/up" &
  local forwarder=$!
  printf '%s\n%s\n' "$server" "$forwarder" > "$tls/proxy.pids"
  for _ in $(seq 1 50); do
    nc -z 127.0.0.1 56398 2>/dev/null && return 0
    sleep 0.1
  done
  echo "TLS proxy did not start" >&2
  return 1
}

stop_tls_proxy() {
  local tls="$DIR/tls"
  if [ -f "$tls/proxy.pids" ]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$tls/proxy.pids"
    rm -f "$tls/proxy.pids"
  fi
  rm -f "$tls/up" "$tls/down"
}

stop_port() { # port pidfile
  if running "$1"; then
    CLI -p "$1" shutdown nosave >/dev/null 2>&1 || true
  fi
  if [ -f "$2" ] && kill -0 "$(cat "$2")" 2>/dev/null; then kill "$(cat "$2")" 2>/dev/null || true; fi
  for _ in $(seq 1 50); do running "$1" || return 0; sleep 0.1; done
}

case "${1:-status}" in
  start)
    mkdir -p "$DIR"
    start_node 56380
    start_node 56381 "replicaof 127.0.0.1 56380"
    start_sentinel
    start_cluster
    start_tls_proxy
    echo "sentinel mymaster on 127.0.0.1:56382 (master 56380, replica 56381); cluster on 127.0.0.1:56390-56392; TLS proxy on 127.0.0.1:56398"
    ;;
  stop)
    stop_tls_proxy
    stop_port 56382 "$DIR/56382/sentinel.pid"
    stop_port 56381 "$DIR/56381/redis.pid"
    stop_port 56380 "$DIR/56380/redis.pid"
    for port in "${CLUSTER_PORTS[@]}"; do stop_port "$port" "$DIR/$port/redis.pid"; done
    echo stopped
    ;;
  status)
    for port in 56380 56381 56382 "${CLUSTER_PORTS[@]}"; do
      running "$port" && echo "$port running" || echo "$port stopped"
    done
    nc -z 127.0.0.1 56398 2>/dev/null && echo "56398 TLS proxy running" || echo "56398 TLS proxy stopped"
    ;;
  reset)
    "$0" stop
    rm -rf "$DIR"
    ;;
  *)
    echo "usage: $0 start|stop|status|reset" >&2
    exit 64
    ;;
esac
