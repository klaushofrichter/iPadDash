#!/bin/sh
# Screenshot every iPadDash page on the USB-connected iPad, waiting for
# auto-move to cycle through them. Writes page-1.png ... page-N.png to OUT_DIR.
#
# Usage: capture.sh OUT_DIR [PAGES=4] [TIMEOUT_SECONDS=600]
# Exits 2 (listing the missing pages) if not all pages showed up in time,
# e.g. auto-move is set to None or a page is frozen.
set -eu

OUT=$1; PAGES=${2:-4}; TIMEOUT=${3:-600}
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=${TMPDIR:-/tmp}/ipaddash-pagedot
[ "$TOOL" -nt "$HERE/pagedot.swift" ] || swiftc -O "$HERE/pagedot.swift" -o "$TOOL"

mkdir -p "$OUT"
rm -f "$OUT"/page-*.png "$OUT"/.probe*.png
end=$(( $(date +%s) + TIMEOUT ))
have() { ls "$OUT" | grep -c '^page-[0-9]*\.png$' || true; }

while [ "$(have)" -lt "$PAGES" ] && [ "$(date +%s)" -lt "$end" ]; do
    idevicescreenshot "$OUT/.probe.png" >/dev/null
    p=$("$TOOL" "$OUT/.probe.png")
    if [ "$p" != 0 ] && [ ! -f "$OUT/page-$p.png" ]; then
        # Let the fade settle, then keep the shot only if it is still that page.
        sleep 2
        idevicescreenshot "$OUT/.probe2.png" >/dev/null
        [ "$("$TOOL" "$OUT/.probe2.png")" = "$p" ] && mv "$OUT/.probe2.png" "$OUT/page-$p.png" \
            && echo "page $p $(date +%H:%M:%S)"
    fi
    sleep 3
done
rm -f "$OUT"/.probe*.png

missing=""
i=1; while [ $i -le "$PAGES" ]; do [ -f "$OUT/page-$i.png" ] || missing="$missing $i"; i=$((i + 1)); done
[ -z "$missing" ] || { echo "missing pages:$missing (auto-move off, page frozen, or app not in front?)" >&2; exit 2; }
