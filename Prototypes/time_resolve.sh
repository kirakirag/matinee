#!/bin/bash
# Throwaway: time yt-dlp resolution 4 ways (worker/CLI x plain/sandboxed), cold then warm.
set -u
P=$(cd "$(dirname "$0")" && pwd)
PY=/opt/homebrew/opt/yt-dlp/libexec/bin/python
C=$P/out/cache
IDS=$P/out/ids.txt
OUT=$P/out/resolve.tsv
FMT='bv*[height<=1080]+ba/b'
printf 'mode\trun\tid\tms\theight\terror\n' > "$OUT"

run_env() {  # run a command in a clean env, from the cache dir, optionally sandboxed
  local sandboxed=$1; shift
  local pre=()
  [ "$sandboxed" = 1 ] && pre=(sandbox-exec -D "CACHE=$C" -D "SCRIPT=$P/resolve_worker.py" -f "$P/ytdlp.sb")
  (cd "$C" && env -i HOME="$C" XDG_CACHE_HOME="$C" DENO_DIR="$C/deno" TMPDIR="$C/tmp" \
     PATH=/opt/homebrew/bin:/usr/bin:/bin ${pre[@]+"${pre[@]}"} "$@")
}

worker() {  # mode run sandboxed
  run_env "$3" "$PY" -I "$P/resolve_worker.py" < "$IDS" 2>/dev/null |
    "$PY" -I -c 'import json,sys
for l in sys.stdin:
    d=json.loads(l); print(sys.argv[1],sys.argv[2],d["id"],d["ms"],d["height"],(d["error"] or "")[:80],sep="\t")' "$1" "$2" >> "$OUT"
}

cli() {  # mode run sandboxed
  while read -r id; do
    local t0 t1 h
    t0=$("$PY" -c 'import time;print(time.perf_counter_ns())')
    h=$(run_env "$3" "$PY" -I -m yt_dlp -J --ignore-config --no-plugin-dirs --js-runtimes deno -f "$FMT" \
          "https://www.youtube.com/watch?v=$id" 2>/dev/null |
        "$PY" -I -c 'import json,sys
try: d=json.load(sys.stdin); print(max((f.get("height") or 0) for f in d.get("requested_formats") or [d]))
except Exception as e: print("0\t"+str(e)[:60])')
    t1=$("$PY" -c 'import time;print(time.perf_counter_ns())')
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$id" $(( (t1 - t0) / 1000000 )) "$h" >> "$OUT"
  done < "$IDS"
}

for mode in worker worker-sb cli cli-sb; do
  sb=0; [[ $mode == *-sb ]] && sb=1
  rm -rf "$C"; mkdir -p "$C/tmp"
  for run in cold warm; do
    case $mode in worker*) worker "$mode" "$run" "$sb" ;; cli*) cli "$mode" "$run" "$sb" ;; esac
  done
done
column -t -s $'\t' "$OUT"
