#!/bin/bash
# Smoke test java_27 (Ubuntu 26.04 resolute) against java_26 (noble), run the way Wings runs a server.
set -uo pipefail
FAILED=0
pass() { echo "PASS: $*"; echo "| ✅ | $* |" >> "$GITHUB_STEP_SUMMARY"; }
fail() { echo "FAIL: $*"; echo "| ❌ | $* |" >> "$GITHUB_STEP_SUMMARY"; FAILED=1; }
echo "| | check |" >> "$GITHUB_STEP_SUMMARY"; echo "|---|---|" >> "$GITHUB_STEP_SUMMARY"

# Latest Minecraft release server jar, a typical workload for these images
MC=$(curl -fsSL https://piston-meta.mojang.com/mc/game/version_manifest_v2.json | jq -r '.latest.release')
curl -fsSL "$(curl -fsSL https://piston-meta.mojang.com/mc/game/version_manifest_v2.json | jq -r --arg v "$MC" '.versions[]|select(.id==$v).url')" \
  | jq -r '.downloads.server.url' | xargs curl -fsSL -o /tmp/server.jar

for v in 26 27; do
  img=test:java_$v
  docker run --rm --user 988:988 --entrypoint bash "$img" -c '
    echo "$(. /etc/os-release; echo $PRETTY_NAME) | $(java -version 2>&1 | head -1)"
    for c in java curl lsof openssl git tar sqlite3 zip unzip jq tini ip fc-list; do command -v $c >/dev/null || echo "MISSING $c"; done' | tee "/tmp/$v.info"
  grep -q MISSING "/tmp/$v.info" && fail "java_$v: missing tools" || pass "java_$v: all packages from the Dockerfile are installed"
  docker run --rm --entrypoint dpkg-query "$img" -W -f '${Package} ${Version}\n' | sort > "/tmp/$v.pkgs"

  # Wings-like run: uid 988, /home/container mounted, STARTUP evaluated by the image's entrypoint
  d=$(mktemp -d); cp /tmp/server.jar "$d/server.jar"; echo "eula=true" > "$d/eula.txt"; sudo chown -R 988:988 "$d"
  docker run -d --name mc$v --user 988:988 -v "$d:/home/container" -e SERVER_MEMORY=1024 -e SERVER_PORT=25565 \
    -e STARTUP='java -Xms128M -Xmx{{SERVER_MEMORY}}M -jar server.jar nogui --port {{SERVER_PORT}}' "$img" >/dev/null
  ok=0; for _ in $(seq 180); do docker logs mc$v 2>&1 | grep -q 'Done (' && { ok=1; break; }; sleep 1; done
  if [ $ok = 1 ]; then pass "java_$v: Minecraft $MC server starts (Done)"; else fail "java_$v: Minecraft $MC did not start"; docker logs mc$v 2>&1 | tail -30; fi
  ip_entry=$(docker exec mc$v bash -c "ip route get 1 | awk '{print \$(NF-2);exit}'")
  ip_real=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mc$v)
  [ "$ip_entry" = "$ip_real" ] && pass "java_$v: INTERNAL_IP parsing ($ip_entry)" || fail "java_$v: INTERNAL_IP '$ip_entry' != '$ip_real'"
  # STOPSIGNAL SIGINT through tini must stop the server cleanly (the panel stop button)
  docker stop -t 60 mc$v >/dev/null; code=$(docker inspect -f '{{.State.ExitCode}}' mc$v)
  docker logs mc$v 2>&1 | grep -qi 'Stopping server' && pass "java_$v: graceful stop on SIGINT (exit $code)" || fail "java_$v: no graceful stop (exit $code)"
  docker rm mc$v >/dev/null
done

{ echo; echo "### Packages: java_26 (noble) -> java_27 (resolute)"; echo '```'
  join -a1 -a2 -e '-' -o 0,1.2,2.2 /tmp/26.pkgs /tmp/27.pkgs | awk '$2!=$3' | column -t
  echo '```'; } >> "$GITHUB_STEP_SUMMARY"
join -a1 -a2 -e '-' -o 0,1.2,2.2 /tmp/26.pkgs /tmp/27.pkgs | awk '$2!=$3' | column -t
cat /tmp/26.info /tmp/27.info
exit $FAILED
