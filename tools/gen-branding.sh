#!/usr/bin/env bash
# ASM Industries branding generator (wallpaper, boot splash, logos).
# Usage: gen-branding.sh <output-dir> [version]
# Needs ImageMagick and fonts-dejavu-core on the BUILD host (build.sh installs them).
set -Eeuo pipefail

OUT="${1:?usage: gen-branding.sh <output-dir> [version]}"
VER="${2:-1.0}"
mkdir -p "$OUT"

IM=$(command -v magick || command -v convert) || { echo "ImageMagick not found" >&2; exit 1; }

BOLD=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
REG=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
FONT_ARGS_BOLD=(); FONT_ARGS_REG=()
[[ -f $BOLD ]] && FONT_ARGS_BOLD=(-font "$BOLD")
[[ -f $REG  ]] && FONT_ARGS_REG=(-font "$REG")

# Palette
BG1='#070a10'; BG2='#111a2a'; ACCENT='#00a3ff'; FG='#e6edf3'; MUTED='#7f8ea3'

# --- Wallpaper 1920x1080: dark gradient, soft ring motif, wordmark ---------
"$IM" -size 1920x1080 "gradient:${BG1}-${BG2}" \
    -fill none -stroke "${ACCENT}" -strokewidth 1 \
    \( -size 1920x1080 xc:none -stroke 'rgba(0,163,255,0.16)' -strokewidth 2 -fill none \
       -draw 'circle 1500,330 1500,730' -draw 'circle 1500,330 1500,610' -draw 'circle 1500,330 1500,490' \) -compose over -composite \
    -stroke none -fill "${FG}" "${FONT_ARGS_BOLD[@]}" -kerning 14 -pointsize 110 \
    -gravity southwest -annotate +120+190 'ASM OS' \
    -fill "${ACCENT}" "${FONT_ARGS_REG[@]}" -kerning 10 -pointsize 26 \
    -annotate +124+140 'ASM INDUSTRIES' \
    -depth 8 "$OUT/wallpaper.png"

# --- Plymouth logo (transparent) and progress bar ---------------------------
"$IM" -size 640x220 xc:none \
    -fill "${FG}" "${FONT_ARGS_BOLD[@]}" -kerning 16 -pointsize 96 \
    -gravity center -annotate +0-24 'ASM OS' \
    -fill "${ACCENT}" "${FONT_ARGS_REG[@]}" -kerning 12 -pointsize 22 \
    -annotate +0+56 'ASM INDUSTRIES' \
    -depth 8 "$OUT/logo.png"
"$IM" -size 400x6 "xc:${ACCENT}" -depth 8 "$OUT/bar.png"

# --- 640x480 boot menu background (ISOLINUX + GRUB) ---------------------------
"$IM" -size 640x480 "gradient:${BG1}-${BG2}" \
    -fill "${FG}" "${FONT_ARGS_BOLD[@]}" -kerning 8 -pointsize 44 \
    -gravity north -annotate +0+28 'ASM OS' \
    -fill "${ACCENT}" "${FONT_ARGS_REG[@]}" -kerning 6 -pointsize 13 \
    -annotate +0+84 'ASM INDUSTRIES' \
    -fill "${MUTED}" "${FONT_ARGS_REG[@]}" -kerning 0 -pointsize 11 \
    -gravity south -annotate +0+14 "version ${VER}" \
    -depth 8 "$OUT/bootsplash.png"

# --- 64x64 launcher/menu icon -----------------------------------------------
"$IM" -size 64x64 xc:none -fill "${ACCENT}" -draw 'roundrectangle 2,2 61,61 14,14' \
    -fill "${BG1}" "${FONT_ARGS_BOLD[@]}" -pointsize 34 -gravity center -annotate +0+1 'A' \
    -depth 8 "$OUT/icon.png"

echo "branding written to $OUT"
