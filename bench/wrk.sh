#!/usr/bin/env bash
# Benchmarks the server with wrk across worker configurations.
#
# Usage: bench/wrk.sh [variant...]
#   variant: <label>:<reuse_port>:<num_workers>, e.g. acceptor8:false:8 (default: a preset list)
# Env: DURATION (20s), CONNECTIONS (512), WRK_THREADS (4), SERVER_CPUS (0-7), WRK_CPUS (8-11),
#      URL (http://127.0.0.1:2500/), WRK_ARGS (extra wrk arguments, shell-quoted, e.g. "-H 'Connection: close'").
#      Set SERVER_CPUS= and WRK_CPUS= to disable pinning.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v wrk >/dev/null || { echo "wrk is not installed" >&2; exit 1; }

DURATION=${DURATION:-20s}
CONNECTIONS=${CONNECTIONS:-512}
WRK_THREADS=${WRK_THREADS:-4}
SERVER_CPUS=${SERVER_CPUS-0-7}
WRK_CPUS=${WRK_CPUS-8-11}
URL=${URL:-http://127.0.0.1:2500/}
eval "wrk_args=(${WRK_ARGS:-})"
OUT=$(mktemp -d)

variants=("$@")
[ ${#variants[@]} -eq 0 ] && variants=(single:false:0 acceptor4:false:4 acceptor8:false:8 reuse_port4:true:4 reuse_port8:true:8)

# num_workers is comptime, so each variant is a rebuild with a patched main.zig.
pattern='azig.Config{ .reuse_port = true }'
grep -qF "$pattern" src/main.zig || { echo "src/main.zig does not contain: $pattern" >&2; exit 1; }
cp src/main.zig "$OUT/main.zig"
trap 'cp "$OUT/main.zig" src/main.zig' EXIT

# Not a shell function: a backgrounded function is a subshell, which ignores SIGINT.
server_cmd=(./zig-out/bin/azig)
[ -n "$SERVER_CPUS" ] && server_cmd=(taskset -c "$SERVER_CPUS" "${server_cmd[@]}")
wrk_cmd=(wrk)
[ -n "$WRK_CPUS" ] && wrk_cmd=(taskset -c "$WRK_CPUS" wrk)

for variant in "${variants[@]}"; do
    IFS=: read -r label reuse workers <<<"$variant"
    sed "s/$pattern/azig.Config{ .reuse_port = $reuse, .num_workers = $workers }/" "$OUT/main.zig" > src/main.zig
    zig build -Doptimize=ReleaseFast

    "${server_cmd[@]}" >"$OUT/server-$label.log" 2>&1 &
    pid=$!
    for _ in $(seq 50); do curl -s -o /dev/null "$URL" && break; sleep 0.1; done

    "${wrk_cmd[@]}" -t"$WRK_THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency ${wrk_args[@]+"${wrk_args[@]}"} "$URL" >"$OUT/wrk-$label.txt"
    cpu=$(ps -o time= -p "$pid")
    kill -INT "$pid"
    wait "$pid" || true

    echo "== $label (reuse_port=$reuse, num_workers=$workers, server cpu time $cpu)"
    grep -E "Requests/sec|  (50|90|99)%|Non-2xx|Socket errors" "$OUT/wrk-$label.txt"
done
echo "Raw output: $OUT"
