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
# - Fake.stray: a process outside its group (its own session) keeps a copy of fd 4, as a fork beside the host would:
#   its pid goes to $HOME/stray; once this process is reaped it writes {"method":"Fake.fromStray"} there (a pipe no one
#   reads any more refuses it), touches $HOME/stray-wrote, and holds the copy for 30 s.
# - Page.navigate {"url":"http://HOST[:PORT]/PATH"} fetches the URL as Chromium would: straight to a loopback host
#   (127.0.0.1, localhost: Chromium does not proxy them), through --proxy-server's HTTP proxy otherwise (absolute-form).
#   A connect that fails is tried again for 5 s. The result is {"frameId":"F1","status":CODE,"body":BODY}, BODY the
#   response's body with everything but letters, digits, space, `.`, `_` and `-` left out (0 and "": no answer).
# - The pipe's end (EOF on fd 3) ends it.
printf '%s\0' "$@" > "$HOME/argv"
cat "/proc/$$/environ" > "$HOME/environ"
echo "fake-chromium: up" >&2
stubborn= attaches=0 children=0 proxy=
for a in "$@"; do
  [[ $a == --proxy-server=http://* ]] && proxy=${a#--proxy-server=http://}
done
out() { printf '%s\0' "$1" >&4; }
# fetch URL: the whole response on stdout (a subshell: its fd and its failures stay in it)
fetch() (
  url=$1 rest=${1#http://}
  hostport=${rest%%/*} path=/
  [[ $rest == */* ]] && path=/${rest#*/}
  host=${hostport%:*} port=80
  [[ $hostport == *:* ]] && port=${hostport##*:}
  if [[ $host == 127.0.0.1 || $host == localhost ]]; then
    to=127.0.0.1/$port req="GET $path HTTP/1.0"
  else
    to=${proxy%:*}/${proxy##*:} req="GET $url HTTP/1.0"
  fi
  for _ in $(seq 50); do
    { printf '%s\r\nHost: %s\r\nConnection: close\r\n\r\n' "$req" "$hostport" >&7; cat <&7; } 7<>"/dev/tcp/$to" &&
      exit 0
    sleep 0.1
  done 2>/dev/null
  exit 1
)
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
    Fake.stray) setsid -f sh -c 'trap "" PIPE; echo $$ > "$HOME/stray"; while [ -e /proc/'"$$"' ]; do sleep 0.01; done
      printf "{\"method\":\"Fake.fromStray\"}\0" >&4; touch "$HOME/stray-wrote"; exec sleep 30' ;;
    Target.attachToBrowserTarget) attaches=$((attaches + 1)); result="{\"sessionId\":\"browser-$attaches\"}" ;;
    Target.detachFromTarget) result='{}' ;;
    Page.navigate)
      url=
      [[ $msg =~ \"url\":\"([^\"]+)\" ]] && url=${BASH_REMATCH[1]}
      resp=$(fetch "$url")
      code=0 body=
      [[ $resp =~ ^HTTP/1\.[01]\ ([0-9]+) ]] && code=${BASH_REMATCH[1]}
      [[ $resp == *$'\r\n\r\n'* ]] && body=${resp#*$'\r\n\r\n'}
      body=${body//[^A-Za-z0-9 ._-]/}
      result="{\"frameId\":\"F1\",\"status\":$code,\"body\":\"$body\"}" ;;
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
