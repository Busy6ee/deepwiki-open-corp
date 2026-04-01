#!/bin/sh
# Copy vendor assets to public/ for local serving (no external CDN needed)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

mkdir -p "$PROJECT_DIR/public/vendor/fontawesome/css"
mkdir -p "$PROJECT_DIR/public/vendor/fontawesome/webfonts"
mkdir -p "$PROJECT_DIR/public/vendor/chartjs"
mkdir -p "$PROJECT_DIR/public/vendor/mermaid"

cp "$PROJECT_DIR/node_modules/@fortawesome/fontawesome-free/css/all.min.css" \
   "$PROJECT_DIR/public/vendor/fontawesome/css/"
cp "$PROJECT_DIR/node_modules/@fortawesome/fontawesome-free/webfonts/"* \
   "$PROJECT_DIR/public/vendor/fontawesome/webfonts/"
cp "$PROJECT_DIR/node_modules/chart.js/dist/chart.umd.js" \
   "$PROJECT_DIR/public/vendor/chartjs/"
cp "$PROJECT_DIR/node_modules/mermaid/dist/mermaid.min.js" \
   "$PROJECT_DIR/public/vendor/mermaid/"

echo "Vendor assets copied to public/vendor/"
