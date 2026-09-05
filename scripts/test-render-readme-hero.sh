#!/usr/bin/env bash
# Offline rendering regression tests; requires Bash and ImageMagick 7.
set -euo pipefail
export LC_ALL=C MAGICK_THREAD_LIMIT=1
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
RENDER="$ROOT/scripts/render-readme-hero.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-readme-hero.XXXXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() {
  if "$RENDER" "$@" >"$WORK/rejected.log" 2>&1; then fail "Accepted invalid input: $*"; fi
}
equal_pixels() {
  magick compare -metric AE "$1" "$2" null: 2>"$WORK/compare.log" ||
    fail "Pixel comparison failed: $(cat "$WORK/compare.log")"
}

"$RENDER" --help >/dev/null
mkdir -p "$WORK/output with spaces"
SOURCE="$WORK/real path with spaces.png"
NORMAL="$WORK/output with spaces/hero.png"
RETINA="$WORK/output with spaces/hero@2x.png"
# This synthetic colour fixture is only for tests, never README screen content.
magick -size 360x460 gradient:'#021830-#f5c257' \
  -fill '#eb33ff' -draw 'rectangle 20,50 340,65' \
  -fill '#00ddcc' -draw 'rectangle 20,100 340,115' \
  -depth 8 "PNG24:$SOURCE"
cp -- "$SOURCE" "$WORK/unchanged.png"
"$RENDER" "$SOURCE" "$NORMAL" 496 >"$WORK/render.log"
[[ $(magick identify -format '%wx%h' "$NORMAL") == 1898x1190 ]] || fail 'Normal dimensions'
[[ $(magick identify -format '%wx%h' "$RETINA") == 3796x2380 ]] || fail 'Retina dimensions'
[[ $(magick identify -format '%[opaque]' "$NORMAL") == True ]] || fail 'Normal must be opaque'
[[ $(magick identify -format '%[hex:p{0,0}]' "$NORMAL") == 6867AA ]] || fail 'Background colour'

# At native phone height (460+36), scaling is 1:1. The source pixels away from
# the approved corner mask/camera MUST match, at the exact centred coordinates.
# This catches reconstructed/altered pixels AND a leaked +3,+6 shadow offset.
PX=$(((1898 - 396) / 2))
PY=$(((1190 - 496) / 2 - 3))
magick "$SOURCE" -crop 336x400+12+48 +repage "$WORK/expected.png"
magick "$NORMAL" -crop "336x400+$((PX+18+12))+$((PY+18+48))" +repage "$WORK/actual.png"
equal_pixels "$WORK/expected.png" "$WORK/actual.png"
# Preserve status pixels around the centre hinge: the camera belongs on the right.
magick "$SOURCE" -crop 30x30+165+10 +repage "$WORK/expected.png"
magick "$NORMAL" -crop "30x30+$((PX+18+165))+$((PY+18+10))" +repage "$WORK/actual.png"
equal_pixels "$WORK/expected.png" "$WORK/actual.png"
[[ $(magick "$NORMAL" -format "%[hex:p{$((PX+18+270)),$((PY+18+25))}]" info:) == 111522 ]] || fail 'Camera position'
magick "$NORMAL" -filter Lanczos -resize 200% -depth 8 "PNG24:$WORK/expected@2x.png"
equal_pixels "$WORK/expected@2x.png" "$RETINA"
cp -- "$NORMAL" "$WORK/first.png"
cp -- "$RETINA" "$WORK/first@2x.png"
sleep 1
"$RENDER" "$SOURCE" "$NORMAL" 496 >/dev/null
cmp -s "$WORK/first.png" "$NORMAL" || fail 'Normal is not byte-reproducible'
cmp -s "$WORK/first@2x.png" "$RETINA" || fail 'Retina is not byte-reproducible'
cmp -s "$WORK/unchanged.png" "$SOURCE" || fail 'Source was changed'

# Exercise the default framing, JPEG decoding, and a different aspect ratio.
magick -size 480x800 gradient:'#112244-#ddaa66' "$WORK/capture.jpg"
"$RENDER" "$WORK/capture.jpg" "$WORK/jpeg.png" >"$WORK/jpeg.log"
grep -q 'Phone: .*x1000 at ' "$WORK/jpeg.log" || fail 'Default height'
reject "$WORK/missing.png" "$NORMAL"
reject "$SOURCE" "$NORMAL" 0
reject "$SOURCE" "$NORMAL" 0900
reject "$SOURCE" "$NORMAL" 1100
reject "$SOURCE" "$NORMAL" abc
reject "$SOURCE" "$SOURCE"
reject "$RETINA" "$NORMAL"
reject "$SOURCE" "$RETINA"
reject "$SOURCE" "$WORK/not-a-png.jpg"
magick -size 1800x100 xc:black "$WORK/wide.png"
reject "$WORK/wide.png" "$NORMAL"
magick -size 100x100 xc:none "$WORK/transparent.png"
reject "$WORK/transparent.png" "$NORMAL"
magick -size 100x100 xc:black xc:white "$WORK/animated.gif"
reject "$WORK/animated.gif" "$NORMAL"
ln -s "$WORK/unchanged.png" "$WORK/symlink.png"
reject "$SOURCE" "$WORK/symlink.png"

# A failed second render must leave BOTH previously published outputs intact.
export REAL_MAGICK
REAL_MAGICK=$(command -v magick)
mkdir "$WORK/bin"
cat > "$WORK/bin/magick" <<'SHIM'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ $arg != PNG24:*'/hero@2x.png' ]] || exit 99
done
exec "$REAL_MAGICK" "$@"
SHIM
chmod +x "$WORK/bin/magick"
if PATH="$WORK/bin:$PATH" "$RENDER" "$SOURCE" "$NORMAL" 496 >"$WORK/failure.log" 2>&1; then
  fail 'Expected the simulated @2x failure'
else
  [[ $? == 99 ]] || fail 'Did not reach the simulated @2x failure'
fi
cmp -s "$WORK/first.png" "$NORMAL" || fail 'Failed render replaced normal'
cmp -s "$WORK/first@2x.png" "$RETINA" || fail 'Failed render replaced retina'
[[ -z $(find "$WORK/output with spaces" -name '.readme-hero.*' -print) ]] || fail 'Leaked temporary files'
printf 'PASS: pixel fidelity, placement, camera, dimensions, colour, @2x, determinism, inputs and failure safety.\n'
