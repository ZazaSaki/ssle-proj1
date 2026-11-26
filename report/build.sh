#!/bin/bash
# Build the final report PDF: converts the SVG figures to PDF, then compiles with latexmk.
#   cd report && bash build.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
echo "=== SVG figures -> PDF (needs inkscape) ==="
for f in architecture fig_scalability fig_correlation fig_identity_vs_ip fig_dos fig_spam fig_c2 fig_mitm; do
  [ -f "figures/$f.svg" ] && inkscape "$HERE/figures/$f.svg" --export-type=pdf \
    --export-filename="$HERE/figures/$f.pdf" >/dev/null 2>&1 && echo "  $f.pdf"
done
echo "=== compile report.tex ==="
latexmk -pdf -interaction=nonstopmode -halt-on-error report.tex
latexmk -c >/dev/null 2>&1 || true   # remove aux, keep report.pdf
echo "=== done: $HERE/report.pdf ($(pdfinfo report.pdf 2>/dev/null | awk '/Pages/{print $2" pages"}')) ==="
