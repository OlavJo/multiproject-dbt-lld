#!/usr/bin/env bash
# Regenerate the access-map PNGs from their Mermaid sources (*.mmd in this folder).
# Needs Node.js (npx) and a Chromium; set CHROME to its path if puppeteer cannot find one.
set -euo pipefail
cd "$(dirname "$0")"
cfg=$(mktemp)
if [[ -n "${CHROME:-}" ]]; then
  printf '{"executablePath":"%s","args":["--no-sandbox"]}' "$CHROME" > "$cfg"
else
  printf '{"args":["--no-sandbox"]}' > "$cfg"
fi
for f in *.mmd; do
  npx -y @mermaid-js/mermaid-cli@11.4.2 -i "$f" -o "${f%.mmd}.png" -p "$cfg" -w 1600 -s 2 -b white
done
rm -f "$cfg"
