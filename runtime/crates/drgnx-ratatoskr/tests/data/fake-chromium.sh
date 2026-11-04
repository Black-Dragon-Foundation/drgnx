#!/bin/bash
# A stand-in for Chromium in the browser host's tests (docs/develop/hub.md, "The browser host"). It speaks
# --remote-debugging-pipe: messages in on fd 3 and out on fd 4, each ended by a NUL.
#
# - At start it writes its arguments and its environment, NUL-separated as execve passed them, to $HOME/argv and
#   $HOME/environ, and says "fake-chromium: up" on stderr.
# - Every message with an id gets {"id":N,"result":{"echo":MESSAGE}}, with the message's first "sessionId" when it
#   has one; Target.attachToBrowserTarget gets {"sessionId":"fake-browser-session"} instead.
# - Fake.crash: it dies by SIGKILL, as a crash ends it (no core dump).
# - Fake.stubborn: from then on it ignores SIGTERM and outlives the pipe's end, so only SIGKILL stops it.
# - The pipe's end (EOF on fd 3) ends it.
printf '%s\0' "$@" > "$HOME/argv"
cat "/proc/$$/environ" > "$HOME/environ"
echo "fake-chromium: up" >&2
stubborn=
while IFS= read -r -d '' msg <&3; do
  id= method= sid=
  [[ $msg =~ \"id\":([0-9]+) ]] && id=${BASH_REMATCH[1]}
  [[ $msg =~ \"method\":\"([A-Za-z.]+)\" ]] && method=${BASH_REMATCH[1]}
  [[ $msg =~ \"sessionId\":\"([^\"]+)\" ]] && sid=${BASH_REMATCH[1]}
  case $method in
    Fake.crash) kill -KILL $$ ;;
    Fake.stubborn) trap '' TERM; stubborn=1 ;;
  esac
  [[ -n $id ]] || continue
  result="{\"echo\":$msg}"
  [[ $method == Target.attachToBrowserTarget ]] && result='{"sessionId":"fake-browser-session"}'
  if [[ -n $sid ]]; then
    printf '{"id":%s,"result":%s,"sessionId":"%s"}\0' "$id" "$result" "$sid" >&4
  else
    printf '{"id":%s,"result":%s}\0' "$id" "$result" >&4
  fi
done
if [[ -n $stubborn ]]; then
  while :; do sleep 1; done
fi
