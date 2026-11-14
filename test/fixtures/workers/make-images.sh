#!/usr/bin/env bash
# Generate the image-open workload's pictures (committed; rerun only to change them), with ImageMagick:
#   .claude/tmp/ctr.sh --image localhost/drgnx-test-gui:f45 --memory 2g -- bash test/fixtures/workers/make-images.sh
# screenshot-4k.png : a 3840x2160 window-like picture (flat panels, a grid, bars): what an agent's screenshot looks like
# images/NN.(png|jpg): twenty 800x500 pictures, alternating formats, and preview-20.md that shows them
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/images"
draw=()
for i in $(seq 0 39); do
  x=$((80 + (i % 8) * 440)) y=$((200 + (i / 8) * 360))
  draw+=(-fill "rgb($((40 + i * 5)),$((90 + (i * 7) % 120)),$((200 - i * 3)))" -draw "rectangle $x,$y $((x + 400)),$((y + 320))")
done
for i in $(seq 0 60); do draw+=(-stroke "gray$((30 + i))" -draw "line 0,$((i * 36)) 3840,$((i * 36))"); done
convert -size 3840x2160 gradient:'#1e2430-#303a4c' -fill '#2b3345' -draw "rectangle 0,0 3840,120" "${draw[@]}" \
  -define png:compression-level=9 "$here/screenshot-4k.png"
{
  echo "# Twenty pictures"; echo
  for n in $(seq -w 1 20); do
    k=$((10#$n))
    if [ $((k % 2)) -eq 1 ]; then ext=png; else ext=jpg; fi
    h1=$((k * 17 % 360)) h2=$((k * 17 % 360 + 90))
    convert -size 800x500 gradient:"hsl($h1,60%,35%)-hsl($h2,60%,55%)" \
      -fill white -stroke none -draw "circle $((100 + k * 30)),250 $((100 + k * 30)),$((180 + k * 3))" \
      -quality 70 "$here/images/$n.$ext"
    echo "![picture $n](images/$n.$ext)"; echo
  done
} > "$here/preview-20.md"
ls -l "$here/screenshot-4k.png" "$here/images" | head -30
