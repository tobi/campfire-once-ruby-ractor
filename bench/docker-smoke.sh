#!/usr/bin/env bash
cd /home/tobi/src/once/ref-rust
LG=bench/loadgen/target/release/loadgen
for spec in go:4391 rust:4392; do n=${spec%:*}; P=${spec#*:}
 d=/tmp/smoke-$n; rm -rf $d; mkdir -p $d/db $d/storage
 cp -a parity/.seed/default/db/. $d/db/; cp -a parity/.seed/default/storage/. $d/storage/
 args=(); while read -r l; do args+=(-e "$l"); done < <(grep -Ev '^(#|$)' parity/.env.reference)
 docker rm -f smoke-$n >/dev/null 2>&1
 docker run --rm -d --name smoke-$n --network host --user $(id -u):$(id -g) -e HTTP_PORT=$P -e TARGET_PORT=$((P+1000)) "${args[@]}" -v $d/db:/rails/storage/db -v $d/storage:/rails/storage/files campfire-$n:app >/dev/null
 for i in $(seq 100); do curl -fs -o /dev/null localhost:$P/up && break; sleep 0.3; done
 echo "$n up: $(curl -s -o /dev/null -w '%{http_code}' localhost:$P/up)"
 $LG login --base http://127.0.0.1:$P --email david@37signals.com --password secret123456 | head -c 200; echo
 docker logs smoke-$n 2>&1 | tail -n 3
 docker stop smoke-$n >/dev/null
done
