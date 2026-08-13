#!/usr/bin/env bash

# Rebuilds pickleboy-glacier-report.pdf from print.html + print.css + figures/.
# Content is static; this only re-renders. Appendix D's transcript is a captured
# file (src/appendix-d-verify-transcript.txt), deliberately not regenerated here -
# rerun verify-backup.sh yourself if you want a fresher one, then update the HTML.

cd "$(dirname "$0")"

echo "=== 1. Tooling ==="
if weasyprint --version; then
  echo "PASS"
else
  echo "FAIL - weasyprint missing. Install: sudo apt install weasyprint"
  exit 1
fi

echo "=== 2. Fonts ==="
N=$(ls fonts/*.ttf 2>/dev/null | wc -l)
[ "$N" -eq 8 ] && echo "PASS - 8 font files" || echo "FAIL - expected 8 ttf files in fonts/, found $N"
fc-list 2>/dev/null | grep -F -q "IBM Plex" \
  && echo "PASS - Plex installed system-wide (figure text will render in Plex)" \
  || echo "WARN - Plex not in fontconfig; figure text falls back to DejaVu. sudo apt install fonts-ibm-plex"

echo "=== 3. Figures ==="
F=$(ls figures/*.svg 2>/dev/null | wc -l)
[ "$F" -eq 4 ] && echo "PASS - 4 figures" || echo "FAIL - expected 4 SVGs in figures/, found $F"

echo "=== 4. Build ==="
if weasyprint print.html pickleboy-glacier-report.pdf 2>weasyprint.err; then
  echo "PASS - pickleboy-glacier-report.pdf written"
  [ -s weasyprint.err ] && { echo "--- renderer warnings ---"; cat weasyprint.err; }
  rm -f weasyprint.err
else
  echo "FAIL - weasyprint exited nonzero:"
  cat weasyprint.err
  exit 1
fi

echo "=== 5. Sanity ==="
PAGES=$(pdfinfo pickleboy-glacier-report.pdf 2>/dev/null | grep -F "Pages:" | tr -d ' ' | cut -d: -f2)
if [ -z "$PAGES" ]; then
  echo "WARN - pdfinfo unavailable (sudo apt install poppler-utils); skipping page/font checks"
else
  [ "$PAGES" -ge 25 ] && [ "$PAGES" -le 40 ] \
    && echo "PASS - $PAGES pages (target 25-40)" || echo "FAIL - $PAGES pages, outside 25-40"
  EMB=$(pdffonts pickleboy-glacier-report.pdf | grep -F -c "IBM-Plex")
  [ "$EMB" -ge 4 ] && echo "PASS - $EMB embedded IBM Plex faces" || echo "FAIL - only $EMB Plex faces embedded"
  DEJA=$(pdffonts pickleboy-glacier-report.pdf | grep -F -c "DejaVu")
  [ "$DEJA" -eq 0 ] && echo "PASS - no DejaVu fallback" || echo "WARN - $DEJA DejaVu faces present (figure font fallback happened)"
fi
SIZE=$(stat -c %s pickleboy-glacier-report.pdf)
[ "$SIZE" -lt 8388608 ] && echo "PASS - $(( SIZE / 1024 )) KB" || echo "WARN - $(( SIZE / 1048576 )) MB, larger than expected"

echo "=== Done ==="
