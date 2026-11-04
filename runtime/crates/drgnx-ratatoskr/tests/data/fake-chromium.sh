#!/bin/bash
# A stand-in for Chromium in the browser host's and the broker's tests (docs/develop/hub.md, "The browser host"). It
# speaks --remote-debugging-pipe: messages in on fd 3 and out on fd 4, each ended by a NUL.
#
# - At start it writes its arguments and its environment, NUL-separated as execve passed them, to $HOME/argv and
#   $HOME/environ, and says "fake-chromium: up" on stderr. Each message's method and first "sessionId" are appended
#   to $HOME/calls, one line each ("METHOD SESSION", "-" for none).
# - Every message with an id gets {"id":N,"result":{"echo":MESSAGE}}, with the message's first "sessionId" when it
#   has one.
# - Target.attachToBrowserTarget gets {"sessionId":"browser-N"} (N counts up from 1).
# - Target.detachFromTarget is answered {} and followed by Target.detachedFromTarget for its params' sessionId.
# - Fake.attach is answered, then Target.attachedToTarget arrives on the message's session: a page target "T-N" on
#   session "child-N", waiting for the debugger.
# - Fake.crash: it dies by SIGKILL, as a crash ends it (no core dump).
# - Fake.stubborn: from then on it ignores SIGTERM and outlives the pipe's end, so only SIGKILL stops it.
# - The pipe's end (EOF on fd 3) ends it.
printf '%s\0' "$@" > "$HOME/argv"
cat "/proc/$$/environ" > "$HOME/environ"
echo "fake-chromium: up" >&2
stubborn= attaches=0 children=0
out() { printf '%s\0' "$1" >&4; }
while IFS= read -r -d '' msg <&3; do
  id= method= sid= target=
  [[ $msg =~ \"id\":([0-9]+) ]] && id=${BASH_REMATCH[1]}
  [[ $msg =~ \"method\":\"([A-Za-z.]+)\" ]] && method=${BASH_REMATCH[1]}
  [[ $msg =~ \"sessionId\":\"([^\"]+)\" ]] && sid=${BASH_REMATCH[1]}
  [[ $msg =~ \"params\":\{\"sessionId\":\"([^\"]+)\" ]] && target=${BASH_REMATCH[1]}
  echo "$method ${sid:--}" >> "$HOME/calls"
  on=; [[ -n $sid ]] && on=",\"sessionId\":\"$sid\""
  result="{\"echo\":$msg}"
  case $method in
    Fake.crash) kill -KILL $$ ;;
    Fake.stubborn) trap '' TERM; stubborn=1 ;;
    Target.attachToBrowserTarget) attaches=$((attaches + 1)); result="{\"sessionId\":\"browser-$attaches\"}" ;;
    Target.detachFromTarget) result='{}' ;;
  esac
  [[ -n $id ]] && out "{\"id\":$id,\"result\":$result$on}"
  case $method in
    Target.detachFromTarget)
      [[ -n $target ]] && out "{\"method\":\"Target.detachedFromTarget\",\"params\":{\"sessionId\":\"$target\"}$on}" ;;
    Fake.attach)
      children=$((children + 1))
      out "{\"method\":\"Target.attachedToTarget\",\"params\":{\"sessionId\":\"child-$children\",\"targetInfo\":{\"targetId\":\"T-$children\",\"type\":\"page\",\"url\":\"about:blank\"},\"waitingForDebugger\":true}$on}" ;;
  esac
done
if [[ -n $stubborn ]]; then
  while :; do sleep 1; done
fi
