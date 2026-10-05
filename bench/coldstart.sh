#!/usr/bin/env bash
# Cold start (docker run -> first 200 from /up) per image, measured with hyperfine: mean ± sd,
# min/max and percentiles over RUNS runs. Each run gets a fresh seed copy (prepare step, untimed).
#
#   bench/coldstart.sh [OUT_DIR]      env: RUNS=15 SERVER_CPUS=8-11 PORT=4390
set -euo pipefail
REF=${CAMPFIRE_REF_RUST:-/home/tobi/src/once/ref-rust}
OUT=${1:-$(cd "$(dirname "$0")" && pwd)/results/coldstart-$(date +%Y%m%d-%H%M%S)}
RUNS=${RUNS:-15} CPUS=${SERVER_CPUS:-8-11} PORT=${PORT:-4390}
mkdir -p "$OUT"
WORK=$(mktemp -d)
ENVS=$(grep -Ev '^(#|$)' "$REF/parity/.env.reference" | sed 's/^/-e /' | tr '\n' ' ')
NCPU=$(taskset -c "$CPUS" nproc)
cmds=()
for pair in reference=campfire-reference:app go=campfire-go:app rust=campfire-rust:app ruby=campfire-ruby:app; do
  name=${pair%%=*} img=${pair#*=}
  extra=""; [ "$name" = ruby ] && extra="-e WEB_CONCURRENCY=$NCPU"
  cmds+=(-n "$name" --prepare "docker rm -f coldstart >/dev/null 2>&1; rm -rf $WORK/s; mkdir -p $WORK/s/db $WORK/s/storage; cp -a $REF/parity/.seed/default/db/. $WORK/s/db/; cp -a $REF/parity/.seed/default/storage/. $WORK/s/storage/; sync"
    "docker run -d --name coldstart --cpuset-cpus $CPUS --user $(id -u):$(id -g) --network host --add-host localhost:127.0.0.1 -e HTTP_PORT=$PORT -e TARGET_PORT=$((PORT + 1)) $ENVS $extra -v $WORK/s/db:/rails/storage/db -v $WORK/s/storage:/rails/storage/files $img >/dev/null && until curl -fsS -o /dev/null http://127.0.0.1:$PORT/up 2>/dev/null; do sleep 0.01; done")
done
hyperfine --runs "$RUNS" --warmup 1 --cleanup "docker rm -f coldstart >/dev/null 2>&1" \
  --export-json "$OUT/coldstart.json" --export-markdown "$OUT/coldstart.md" "${cmds[@]}"
docker rm -f coldstart >/dev/null 2>&1 || true
rm -rf "$WORK"
