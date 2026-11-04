#!/bin/bash
# A stand-in for Chromium in the doctor's browser check (tests/browser_sandboxed.rs, `the_check_takes_a_screenshot`).
# It speaks --remote-debugging-pipe (messages in on fd 3 and out on fd 4, each ended by a NUL) and answers only what the
# check asks: a target for createTarget, a session for attachToTarget, and a fixed 70-byte PNG for captureScreenshot.
# Every other message with an id gets an empty result.
if [[ ${1:-} == --version ]]; then echo "HeadlessChrome 1.0.0.0"; exit 0; fi
echo "fake-chromium-png: up" >&2
attaches=0
out() { printf '%s\0' "$1" >&4; }
while IFS= read -r -d '' msg <&3; do
  id= method= sid=
  [[ $msg =~ \"id\":([0-9]+) ]] && id=${BASH_REMATCH[1]}
  [[ $msg =~ \"method\":\"([A-Za-z.]+)\" ]] && method=${BASH_REMATCH[1]}
  [[ $msg =~ \"sessionId\":\"([^\"]+)\" ]] && sid=${BASH_REMATCH[1]}
  on=; [[ -n $sid ]] && on=",\"sessionId\":\"$sid\""
  result='{}'
  case $method in
    Target.attachToBrowserTarget) attaches=$((attaches + 1)); result="{\"sessionId\":\"browser-$attaches\"}" ;;
    Target.createTarget) result='{"targetId":"T-1"}' ;;
    Target.attachToTarget) result='{"sessionId":"page-1"}' ;;
    Page.captureScreenshot) result='{"data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="}' ;;
  esac
  [[ -n $id ]] && out "{\"id\":$id,\"result\":$result$on}"
done
