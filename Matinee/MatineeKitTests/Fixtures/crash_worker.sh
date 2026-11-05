#!/bin/sh
PATH=/usr/bin:/bin
# Fake worker that crashes on its first request, the first time it is launched (STATE=<file> marks that
# the crash happened). Later launches behave like fake_worker.sh in normal mode.
if [ -e "$STATE" ]; then
    MODE=normal exec /bin/sh "$(dirname "$0")/fake_worker.sh"
fi
echo '{"ready":true}'
: > "$STATE"
IFS= read -r line
exit 1
