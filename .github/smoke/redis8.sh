#!/bin/bash
# Smoke test for yolks:redis_8 on bookworm vs trixie, run the way Wings runs a server:
# non-root uid 988, server files mounted at /home/container, STARTUP with panel variables already substituted.
set -uo pipefail

EGGS=https://raw.githubusercontent.com/TH3N3WN00B/parkervcp-eggs/redis8-dragonfly-updates/database
PW='P@55]w0rd'          # special characters on purpose, like real panel passwords
FAILED=0
pass() { echo "PASS: $*"; echo "| ✅ | $* |" >> "$GITHUB_STEP_SUMMARY"; }
fail() { echo "FAIL: $*"; echo "| ❌ | $* |" >> "$GITHUB_STEP_SUMMARY"; FAILED=1; }

# The panel replaces {{VAR}} before Wings passes STARTUP to the container.
startup_of() { # egg-json-url
  curl -fsSL "$1" | jq -r --arg pw "$PW" '.startup
    | gsub("\\{\\{SERVER_PASSWORD\\}\\}"; $pw) | gsub("\\{\\{SERVER_PORT\\}\\}"; "6379")
    | gsub("\\{\\{SERVER_MEMORY\\}\\}"; "0") | gsub("\\{\\{DF_THREADS\\}\\}"; "1")'
}

new_dir() { local d; d=$(mktemp -d); sudo chown 988:988 "$d"; echo "$d"; }

# start NAME IMAGE DIR STARTUP MARKER -> container running, console stdin on fd 3
start() {
  local name=$1 image=$2 dir=$3 startup=$4 marker=$5
  rm -f "/tmp/$name.in"; mkfifo "/tmp/$name.in"
  docker run -i --name "$name" --user 988:988 -v "$dir:/home/container" \
    -e STARTUP="$startup" -e SERVER_PORT=6379 -e SERVER_PASSWORD="$PW" -e SERVER_MEMORY=0 \
    -e SNAPSHOT_CRON="" -e DF_THREADS=1 \
    "$image" < "/tmp/$name.in" > "/tmp/$name.log" 2>&1 &
  exec 3>"/tmp/$name.in"
  for _ in $(seq 90); do grep -q "$marker" "/tmp/$name.log" && return 0; sleep 1; done
  echo "--- $name log ---"; cat "/tmp/$name.log"; return 1
}

console() { echo "$1" >&3; sleep 2; }   # type a line in the panel console

# stop NAME: close the console (redis-cli exits) so the startup runs its "shutdown save"
stop() {
  exec 3>&-
  for _ in $(seq 30); do [ "$(docker inspect -f '{{.State.Running}}' "$1")" = false ] && break; sleep 1; done
  docker rm -f "$1" >/dev/null
}

cli() { docker exec "$1" redis-cli -p 6379 -a "$PW" --no-auth-warning "${@:2}"; }

echo "| | check |" >> "$GITHUB_STEP_SUMMARY"; echo "|---|---|" >> "$GITHUB_STEP_SUMMARY"

for base in bookworm trixie; do
  img=test:$base
  # 1. What the image and the eggs rely on
  docker run --rm --user 988:988 "$img" bash -c '
    echo "debian $(cat /etc/debian_version) | $(redis-server --version | cut -d" " -f3) | $(ldd --version | head -1)"
    echo "$(ip -V) | $(bash --version | head -1)"
    for c in bash ip awk sed grep sleep kill redis-server redis-cli; do command -v $c >/dev/null || echo "MISSING $c"; done
    ldd /usr/local/bin/redis-server | grep "not found" || true' | tee "/tmp/$base.info"
  grep -q MISSING "/tmp/$base.info" && fail "$base: missing commands" || pass "$base: all commands used by the entrypoint and eggs exist"
  grep -q "not found" "/tmp/$base.info" && fail "$base: redis-server missing libraries" || pass "$base: redis-server libraries resolve"
  docker run --rm "$img" dpkg-query -W -f '${Package} ${Version}\n' | sort > "/tmp/$base.pkgs"

  # 2. Redis 8 egg: start, console commands, INTERNAL_IP, persistence across restart
  d=$(new_dir); curl -fsSL "$EGGS/redis/redis-8/redis.conf" -o /tmp/redis.conf; sudo install -o 988 -g 988 /tmp/redis.conf "$d/redis.conf"
  S8=$(startup_of "$EGGS/redis/redis-8/egg-redis-8.json")
  if start "r8-$base" "$img" "$d" "$S8" "redis_version:"; then
    pass "$base: Redis 8 egg starts and prints $(grep -o 'redis_version:[0-9.]*' /tmp/r8-$base.log)"
    console "SET egg_key from_console"; console "SAVE"
    grep -q '^OK' "/tmp/r8-$base.log" && pass "$base: console commands work (SET/SAVE)" || fail "$base: console commands"
    ip_entry=$(docker exec "r8-$base" bash -c "ip route get 1 | awk '{print \$(NF-2);exit}'")
    ip_real=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "r8-$base")
    [ "$ip_entry" = "$ip_real" ] && pass "$base: INTERNAL_IP parsing ($ip_entry)" || fail "$base: INTERNAL_IP '$ip_entry' != '$ip_real'"
    stop "r8-$base"
    sudo test -s "$d/dump.rdb" && pass "$base: dump.rdb written on stop" || fail "$base: no dump.rdb after stop"
    start "r8b-$base" "$img" "$d" "$S8" "redis_version:" && [ "$(cli r8b-$base GET egg_key)" = from_console ] \
      && pass "$base: data survives a restart" || fail "$base: data lost after restart"
    stop "r8b-$base"
  else fail "$base: Redis 8 egg did not start"; fi

  # 3. Dragonfly egg (needs glibc from this image)
  for v in 1.27.1 latest; do
    d=$(new_dir)
    url=https://github.com/dragonflydb/dragonfly/releases/download/v$v/dragonfly-x86_64.tar.gz
    [ $v = latest ] && url=https://github.com/dragonflydb/dragonfly/releases/latest/download/dragonfly-x86_64.tar.gz
    curl -fsSL "$url" | tar -xz -C /tmp dragonfly-x86_64 && sudo install -o 988 -g 988 /tmp/dragonfly-x86_64 "$d/dragonfly"
    if start "df-$base" "$img" "$d" "$(startup_of "$EGGS/dragonflydb/egg-dragonflydb.json")" "dragonfly_version:"; then
      console "SET df_key 1"
      pass "$base: Dragonfly $v starts ($(grep -o 'dragonfly_version:[^ ]*' /tmp/df-$base.log | tr -d '\r'))"
    else fail "$base: Dragonfly $v did not start"; fi
    stop "df-$base"
  done
done

# 4. Migration: data written by Redis 7.4 (current redis_7) and by the bookworm 8.2 image, loaded by trixie
for src in "ghcr.io/parkervcp/yolks:redis_7|redis-7" "test:bookworm|redis-8"; do
  img=${src%|*}; egg=${src#*|}
  d=$(new_dir); curl -fsSL "$EGGS/redis/$egg/redis.conf" -o /tmp/src.conf; sudo install -o 988 -g 988 /tmp/src.conf "$d/redis.conf"
  start src "$img" "$d" "$(startup_of "$EGGS/redis/$egg/egg-$egg.json")" "redis_version:" || true
  from=$(grep -o 'redis_version:[0-9.]*' /tmp/src.log)
  cli src SET migrated yes >/dev/null; cli src SAVE >/dev/null; stop src
  sudo install -o 988 -g 988 /tmp/redis.conf "$d/redis.conf"   # switch to the Redis 8 config, as when changing egg
  if start dst test:trixie "$d" "$S8" "redis_version:" && [ "$(cli dst GET migrated)" = yes ]; then
    pass "migration $from -> trixie $(grep -o 'redis_version:[0-9.]*' /tmp/dst.log): data loaded"
  else fail "migration $from -> trixie"; cat /tmp/dst.log; fi
  stop dst
done

# 5. Package differences
{ echo; echo "### Packages: bookworm -> trixie"; echo '```'
  join -a1 -a2 -e '-' -o 0,1.2,2.2 /tmp/bookworm.pkgs /tmp/trixie.pkgs | awk '$2!=$3' | column -t
  echo '```'; } >> "$GITHUB_STEP_SUMMARY"
join -a1 -a2 -e '-' -o 0,1.2,2.2 /tmp/bookworm.pkgs /tmp/trixie.pkgs | awk '$2!=$3' | column -t
cat /tmp/bookworm.info /tmp/trixie.info
exit $FAILED
