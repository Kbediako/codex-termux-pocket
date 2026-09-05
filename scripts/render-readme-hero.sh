#!/usr/bin/env bash
# Deterministic, front-on README artwork. Read .github/assets/AGENTS.md first.
# Screen pixels must come from a real screenshot, never generated/retyped UI.
set -euo pipefail
export LC_ALL=C MAGICK_THREAD_LIMIT=1

usage() {
  cat <<'USAGE'
Usage: scripts/render-readme-hero.sh SCREENSHOT OUTPUT.png [PHONE_HEIGHT]

Requires Bash and ImageMagick 7 (magick). Accepts a local PNG or JPEG screenshot.
Writes OUTPUT.png (1898x1190) and OUTPUT@2x.png (3796x2380).
Default phone height: 1000 px; pass 900 to reproduce the original framing.
The input is never overwritten. No network, fonts, or stock images are needed.
USAGE
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
if (( $# < 2 || $# > 3 )); then usage >&2; exit 2; fi
command -v magick >/dev/null 2>&1 || fail 'ImageMagick 7 (magick) is required.'
VERSION=$(magick -version)
[[ $VERSION == 'Version: ImageMagick 7.'* ]] || fail 'magick must be ImageMagick 7.'

INPUT=$1
OUT=$2
TARGET_H=${3:-1000}
[[ -f $INPUT && -r $INPUT ]] || fail 'Screenshot must be a readable local file.'
[[ $OUT == *.png && $OUT != *@2x.png ]] || fail 'Pass the normal output path ending in .png, not @2x.png.'
[[ $TARGET_H =~ ^[1-9][0-9]{0,3}$ ]] || fail 'Phone height must be a positive integer (no leading zeroes).'
OUT2X=${OUT%.png}@2x.png
for path in "$OUT" "$OUT2X"; do
  [[ ! -d $path && ! -L $path ]] || fail "Output is a directory or symlink: $path"
  [[ ! $INPUT -ef $path ]] || fail 'An output would overwrite the source screenshot.'
done

# Resolve the output directory so ImageMagick never interprets a caller's path
# as an option/coder. Work on a byte-for-byte snapshot with a safe local name.
OUT_DIR=$(dirname -- "$OUT")
mkdir -p -- "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)
OUT="$OUT_DIR/$(basename -- "$OUT")"
OUT2X="$OUT_DIR/$(basename -- "$OUT2X")"
WORK=$(mktemp -d "$OUT_DIR/.readme-hero.XXXXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -- "$INPUT" "$WORK/source"
INFO=$(magick identify -format '%m %w %h %[orientation] %[colorspace]\n' "$WORK/source")
[[ $INFO != *$'\n'* ]] || fail 'Use one still screenshot, not a multi-frame image.'
read -r FORMAT SW SH ORIENTATION COLORSPACE <<< "$INFO"
[[ $FORMAT == PNG || $FORMAT == JPEG ]] || fail 'Use a real PNG or JPEG screenshot.'
[[ $COLORSPACE == sRGB || $COLORSPACE == Gray ]] || fail 'Supply an sRGB screenshot; the renderer never recolours pixels.'
[[ $ORIENTATION == Undefined || $ORIENTATION == TopLeft ]] || fail 'Supply an upright screenshot; the renderer never rotates pixels.'
(( SW >= 64 && SH >= 64 && SW <= 8192 && SH <= 8192 )) || fail 'Screenshot dimensions must be between 64 and 8192 pixels.'
[[ $(magick identify -format '%[opaque]' "$WORK/source") == True ]] || fail 'Supply an opaque screenshot, not a transparent screen reconstruction.'

CW=1898
CH=1190
BG='#6867AA'
BEZEL=18
Y_OFFSET=-3
# Keep the device itself and the tight shadow clear of all canvas edges.
# The much softer broad shadow may fade into the canvas boundary.
MARGIN=64
OW=$((SW + 2 * BEZEL))
OH=$((SH + 2 * BEZEL))
PW=$(((OW * TARGET_H + OH / 2) / OH))
PX=$(((CW - PW) / 2))
PY=$(((CH - TARGET_H) / 2 + Y_OFFSET))
(( PX >= MARGIN && PY >= MARGIN && CW - PX - PW >= MARGIN && CH - PY - TARGET_H >= MARGIN )) ||
  fail 'Phone would clip or leave insufficient margin; choose a smaller phone height.'

# Custom SVG chassis only; the reference mockup contributes no stock pixels.
# Force ImageMagick's internal SVG renderer rather than PATH-dependent delegates.
cat > "$WORK/frame.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$OW" height="$OH" viewBox="0 0 $OW $OH">
  <defs>
    <linearGradient id="rim" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0" stop-color="#55555b"/>
      <stop offset="0.35" stop-color="#26262a"/>
      <stop offset="0.8" stop-color="#111114"/>
      <stop offset="1" stop-color="#3b3b40"/>
    </linearGradient>
  </defs>
  <rect x="1.5" y="1.5" width="$((OW-3))" height="$((OH-3))" rx="24"
        fill="url(#rim)" stroke="#69696e" stroke-width="3"/>
  <rect x="8" y="8" width="$((OW-16))" height="$((OH-16))" rx="18" fill="#09090b"/>
  <rect x="$((OW/2-22))" y="2" width="44" height="3" rx="1.5" fill="#111114" opacity="0.85"/>
  <rect x="$((OW/2-22))" y="$((OH-5))" width="44" height="3" rx="1.5" fill="#111114" opacity="0.85"/>
</svg>
SVG
magick -background none -density 96 "MSVG:$WORK/frame.svg" "$WORK/frame.png"

# Only the outer display corners are masked. Do not crop, sharpen, recolour,
# remove version/usage text, or reconstruct the status bar/terminal/keyboard.
cat > "$WORK/screen-mask.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$SW" height="$SH" viewBox="0 0 $SW $SH">
  <rect width="$SW" height="$SH" rx="10" fill="white"/>
</svg>
SVG
magick -background none -density 96 "MSVG:$WORK/screen-mask.svg" -alpha extract "$WORK/screen-mask.png"
magick "$WORK/source" +repage "$WORK/screen-mask.png" -alpha off \
  -compose CopyOpacity -composite "$WORK/screen.png"
magick "$WORK/frame.png" "$WORK/screen.png" -geometry "+$BEZEL+$BEZEL" \
  -compose Over -composite "$WORK/phone-face.png"

# Approved unfolded-Fold correction: camera centred in the RIGHT HALF of the
# display (75% of source width), not over the centre hinge. Never paint out UI
# to make room for it; require a suitable real capture instead.
CAM_X=$((BEZEL + 3 * SW / 4))
CAM_Y=$((BEZEL + 25))
magick "$WORK/phone-face.png" \
  -fill '#050507' -stroke '#35353a' -strokewidth 3 \
  -draw "circle $CAM_X,$CAM_Y $((CAM_X+12)),$CAM_Y" \
  -fill '#111522' -stroke none \
  -draw "circle $CAM_X,$CAM_Y $((CAM_X+5)),$CAM_Y" "$WORK/phone-camera.png"

# FRONT-ON ONLY: one uniform Lanczos resize, followed by integer translation.
# Never add Perspective, rotation, shear, keystone, or an aspect-ratio stretch.
magick "$WORK/phone-camera.png" -filter Lanczos -resize "x$TARGET_H" +repage "$WORK/phone-front.png"
SIZE=$(magick identify -format '%w %h' "$WORK/phone-front.png")
read -r PW PH <<< "$SIZE"
PX=$(((CW - PW) / 2))
PY=$(((CH - PH) / 2 + Y_OFFSET))
magick -size "${CW}x${CH}" xc:none "$WORK/phone-front.png" \
  -geometry "+$PX+$PY" -compose Over -composite "$WORK/phone-placed.png"

# Depth is derived only from the alpha silhouette; never distort the device.
magick "$WORK/phone-placed.png" -alpha extract -blur 0x6 "$WORK/depth-mask.png"
magick -size "${CW}x${CH}" xc:'#101014' "$WORK/depth-mask.png" -alpha off \
  -compose CopyOpacity -composite -channel A -evaluate multiply 0.76 +channel "$WORK/depth.png"
magick "$WORK/phone-placed.png" -alpha extract -blur 0x30 "$WORK/shadow-mask.png"
magick -size "${CW}x${CH}" xc:'#1c1a35' "$WORK/shadow-mask.png" -alpha off \
  -compose CopyOpacity -composite -channel A -evaluate multiply 0.34 +channel "$WORK/shadow.png"

# Geometry is sticky in ImageMagick: explicitly reset the phone layer to +0+0
# after offsetting the full-canvas shadow layers, or the phone drifts by +3,+6.
PNG_FLAGS=(-strip -depth 8 -define png:exclude-chunks=date,time -define png:compression-level=9)
magick -size "${CW}x${CH}" xc:"$BG" \
  "$WORK/shadow.png" -geometry +0+14 -compose Over -composite \
  "$WORK/depth.png" -geometry +3+6 -compose Over -composite \
  "$WORK/phone-placed.png" -geometry +0+0 -compose Over -composite \
  "${PNG_FLAGS[@]}" "PNG24:$WORK/hero.png"
# @2x is deliberately the Lanczos upscale of the SAME normal render.
magick "$WORK/hero.png" -filter Lanczos -resize 200% \
  "${PNG_FLAGS[@]}" "PNG24:$WORK/hero@2x.png"

# Render both successfully before replacing either destination. Renames are
# individually atomic on this filesystem; the pair is not a filesystem transaction.
mv -f -- "$WORK/hero.png" "$OUT"
mv -f -- "$WORK/hero@2x.png" "$OUT2X"
printf 'Created:\n%s\n%s\nSource: %s (%sx%s)\nPhone: %sx%s at +%s+%s\n%s\n' \
  "$OUT" "$OUT2X" "$INPUT" "$SW" "$SH" "$PW" "$PH" "$PX" "$PY" "${VERSION%%$'\n'*}"
