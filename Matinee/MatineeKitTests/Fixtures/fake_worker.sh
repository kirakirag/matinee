#!/bin/sh
PATH=/usr/bin:/bin
# Fake matinee_worker for WorkerClient tests. Run as: /bin/sh fake_worker.sh
#   MODE=normal   answer each request
#   MODE=garbage  print a non-JSON line before each answer
#   MODE=silent   never answer
#   MODE=slow     answer each request after 0.6 s
#   MODE=parallel answer ids starting with s after 1 s in the background, others at once (a concurrent worker)
#   MODE=slowfirst  the first request ever (STATE=<file> marks it) never gets an answer; later ones are answered
#   MODE=group    run in its own process group, start `sleep 60` (pid written to LOG), never answer
#   MODE=list     answer `list` with a fixed page (cursor 1, not done) and `more` with an empty done page
#   MODE=download  answer `download` with progress 10 (bytes only), 50 (with fraction, speed, eta) and 100 of 100
#                  (finishing), then the result
#   MODE=downloadslow  a progress line every 0.2 s for 1 s, then the result (in the background)
#   MODE=downloadhang  one progress line, then never an answer (in the background); `cancel` is answered
#   MODE=comments  answer `comments` with two comments, the second with an invalid author id (cursor 7), and `more`
#                  with a last page of one, and `replies` with one reply
#   MODE=related   answer `related` with two videos, the second with an invalid id
#   MODE=descriptions  answer `descriptions` with two (one empty) and stopped true
#   MODE=descriptionsok  answer `descriptions` with none and stopped false
#   MODE=playlists answer `playlists` with two candidates, the second with an invalid id
#   MODE=reject   answer every request with {"ok":false,"error":"url not allowed"}
#   LOG=<file>    append every request line received
if [ "$MODE" = group ] && [ -z "$IN_GROUP" ]; then
    IN_GROUP=1 exec /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' /bin/sh "$0"
fi
if [ "$MODE" = group ]; then
    sleep 60 >/dev/null 2>&1 &
    echo $! >> "$LOG"
fi
progress() { printf '{"rid":%s,"event":"progress","downloaded":%s,"total":%s}\n' "$1" "$2" "$3"; }
downloaded() {
    printf '{"rid":%s,"ok":true,"error":null,"file":"/m/%s.mp4","bytes":100,"title":"T","channel":"C","channel_id":null,"duration":9.5}\n' "$1" "$2"
}
answer() {
    printf '{"rid":%s,"ok":true,"error":null,"video_url":"https://example.invalid/%s","audio_url":"https://example.invalid/a","height":1080,"vcodec":"vp9","acodec":"opus","expire":1800000000,"headers":{"User-Agent":"x"},"available_at":null,"jsc":"deno","ms":5}\n' "$1" "$2"
}
echo '{"ready":true}'
while IFS= read -r line; do
    [ -n "$LOG" ] && [ "$MODE" != group ] && printf '%s\n' "$line" >> "$LOG"
    rid=$(printf '%s' "$line" | sed -n 's/.*"rid":\([0-9]*\).*/\1/p')
    id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    case "$line" in
        *'"op":"warm"'*) [ "$MODE" = silent ] || [ "$MODE" = group ] || printf '{"rid":%s,"ok":true}\n' "$rid"; continue ;;
    esac
    case "$line" in
        *'"op":"cancel"'*) printf '{"rid":%s,"ok":true,"error":null}\n' "$rid"; continue ;;
    esac
    case "$MODE" in
        download)
            progress "$rid" 10 100
            printf '{"rid":%s,"event":"progress","downloaded":50,"total":100,"fraction":0.5,"speed":2048.5,"eta":24.4,"stage":"downloading"}\n' "$rid"
            printf '{"rid":%s,"event":"progress","downloaded":100,"total":100,"fraction":1.0,"speed":null,"eta":null,"stage":"finishing"}\n' "$rid"
            downloaded "$rid" "$id"; continue ;;
        downloadslow) (for n in 1 2 3 4 5; do sleep 0.2; progress "$rid" "$n" null; done; downloaded "$rid" "$id") & continue ;;
        downloadhang) (progress "$rid" 1 null; sleep 30) & continue ;;
        comments)
            case "$line" in
                *'"op":"replies"'*) printf '{"rid":%s,"ok":true,"error":null,"replies":[{"id":"c1.0","text":"Re","author":"@d"}],"done":false}\n' "$rid" ;;
                *'"op":"more"'*) printf '{"rid":%s,"ok":true,"error":null,"comments":[{"id":"c3","text":"Late","author":"@c"}],"done":true}\n' "$rid" ;;
                *) printf '{"rid":%s,"ok":true,"error":null,"count":1234,"comments":[{"id":"c1","text":"Hi","author":"@a","author_id":"UCaaaaaaaaaaaaaaaaaaaaaa","likes":12,"time":"2 days ago","is_uploader":true,"hearted":false},{"id":"c2","text":"Yo","author":"","author_id":null,"likes":null,"time":null,"is_uploader":false,"hearted":true,"reply_count":670,"has_replies":true}],"cursor":7,"done":false}\n' "$rid" ;;
            esac
            continue ;;
        related) printf '{"rid":%s,"ok":true,"error":null,"videos":[{"kind":"video","id":"aaaaaaaaaaa","title":"A","channel":"C","channel_id":"UCaaaaaaaaaaaaaaaaaaaaaa","duration":61,"views":7,"thumbnail":null,"count":null},{"kind":"video","id":"bad","title":"X"}]}\n' "$rid"; continue ;;
        descriptionsok) printf '{"rid":%s,"ok":true,"error":null,"descriptions":{},"stopped":false}\n' "$rid"; continue ;;
        descriptions) printf '{"rid":%s,"ok":true,"error":null,"descriptions":{"testVideo01":"About it","aaaaaaaaaaa":""},"stopped":true}\n' "$rid"; continue ;;
        playlists) printf '{"rid":%s,"ok":true,"error":null,"playlists":[{"id":"PLaaaaaaaaaaaa","title":"Course"},{"id":"bad","title":"X"}]}\n' "$rid"; continue ;;
        reject) printf '{"rid":%s,"ok":false,"error":"url not allowed"}\n' "$rid"; continue ;;
        list)
            case "$line" in
                *'"op":"list"'*) printf '{"rid":%s,"ok":true,"cursor":1,"title":"T","channel_id":null,"channel":null,"entries":[{"kind":"video","id":"testVideo01","title":"V","channel":"C","channel_id":null,"duration":61,"views":7,"thumbnail":"http://example.invalid/t.jpg","count":null},{"kind":"channel","id":"UCaaaaaaaaaaaaaaaaaaaaaa","title":"Ch","channel":null,"channel_id":null,"duration":null,"views":null,"thumbnail":"https://example.invalid/c.jpg","count":null},{"kind":"playlist","id":"PLaaaaaaaaaaaa","title":"P","channel":null,"channel_id":null,"duration":null,"views":null,"thumbnail":null,"count":3},{"kind":"video","id":"bad","title":"X","channel":null,"channel_id":null,"duration":null,"views":null,"thumbnail":null,"count":null}],"done":false}\n' "$rid" ;;
                *) printf '{"rid":%s,"ok":true,"entries":[],"done":true}\n' "$rid" ;;
            esac
            continue ;;
        silent|group) ;;
        slowfirst) if [ -e "$STATE" ]; then answer "$rid" "$id"; else : > "$STATE"; fi ;;
        slow) sleep 0.6; answer "$rid" "$id" ;;
        parallel) case "$id" in s*) (sleep 1; answer "$rid" "$id") & ;; *) answer "$rid" "$id" ;; esac ;;
        garbage) echo 'this is not json'; answer "$rid" "$id" ;;
        *) answer "$rid" "$id" ;;
    esac
done
