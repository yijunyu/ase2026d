#!/usr/bin/env bash
# analyze-crate.sh — Run rust-diagnostics on one extracted crate
#
# Usage: ./analyze-crate.sh <name> <version> [--keep-src]
#
# Input:   ../fetch/<name>-<version>.crate
# Output:  ../results/<name>-<version>.json
#
# The --keep-src flag preserves extracted source (default: purge after analysis).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
FETCH_DIR="$ROOT/fetch"
SRC_DIR="$ROOT/src"
RESULTS_DIR="$ROOT/results"

NAME="${1:-}"
VERSION="${2:-}"
KEEP_SRC=0

if [ -z "$NAME" ] || [ -z "$VERSION" ]; then
    echo "Usage: $0 <name> <version> [--keep-src]" >&2
    exit 1
fi

for arg in "${@:3}"; do
    if [ "$arg" = "--keep-src" ]; then
        KEEP_SRC=1
    fi
done

TARBALL="$FETCH_DIR/${NAME}-${VERSION}.crate"
EXTRACT_DIR="$SRC_DIR/${NAME}-${VERSION}"
RESULT_FILE="$RESULTS_DIR/${NAME}-${VERSION}.json"

mkdir -p "$SRC_DIR" "$RESULTS_DIR"

# Skip if already analyzed
if [ -f "$RESULT_FILE" ]; then
    echo "[skip] $NAME-$VERSION already analyzed"
    exit 0
fi

if [ ! -f "$TARBALL" ]; then
    echo "ERROR: tarball not found: $TARBALL" >&2
    echo '{"name":"'"$NAME"'","version":"'"$VERSION"'","error":"tarball_missing"}' > "$RESULT_FILE"
    exit 1
fi

echo "[extract] $NAME-$VERSION..."
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL" -C "$SRC_DIR" 2>/dev/null || {
    echo "ERROR: failed to extract $TARBALL" >&2
    echo '{"name":"'"$NAME"'","version":"'"$VERSION"'","error":"extract_failed"}' > "$RESULT_FILE"
    rm -rf "$EXTRACT_DIR"
    exit 1
}

# crates.io tarballs extract to <name>-<version>/ subdirectory
# Handle both cases: direct extraction and nested directory
if [ ! -d "$EXTRACT_DIR" ]; then
    # tarball may have created a differently named directory — find it
    EXTRACT_DIR=$(find "$SRC_DIR" -maxdepth 1 -name "${NAME}-${VERSION}*" -type d | head -1)
    if [ -z "$EXTRACT_DIR" ]; then
        echo "ERROR: extraction produced no directory for $NAME-$VERSION" >&2
        echo '{"name":"'"$NAME"'","version":"'"$VERSION"'","error":"extract_no_dir"}' > "$RESULT_FILE"
        exit 1
    fi
fi

echo "[analyze] $NAME-$VERSION in $EXTRACT_DIR..."

# Run rust-diagnostics --count to get warning statistics
# Capture output; handle crates that fail to compile
rd_output=$(rust-diagnostics --folder "$EXTRACT_DIR" --count --warning-per-KLOC 2>&1) || rd_exit=$?
rd_exit=${rd_exit:-0}

# Parse output into JSON using python
python3 - "$NAME" "$VERSION" "$EXTRACT_DIR" "$RESULT_FILE" "$rd_exit" << 'EOF'
import json, sys, os, subprocess, re

name = sys.argv[1]
version = sys.argv[2]
extract_dir = sys.argv[3]
result_file = sys.argv[4]
rd_exit = int(sys.argv[5])

# Count LOC in the extracted source
loc = 0
try:
    result = subprocess.run(
        ["find", extract_dir, "-name", "*.rs", "-not", "-path", "*/target/*"],
        capture_output=True, text=True
    )
    rs_files = [f for f in result.stdout.strip().split('\n') if f]
    for fpath in rs_files:
        try:
            with open(fpath, 'r', errors='replace') as fh:
                loc += sum(1 for _ in fh)
        except Exception:
            pass
except Exception:
    pass

# Read rust-diagnostics output from stdin (captured before this script)
# Re-run rust-diagnostics in JSON-friendly mode
rd_json = None
warnings_total = None
warnings_per_kloc = None
lint_counts = {}

try:
    proc = subprocess.run(
        ["rust-diagnostics", "--folder", extract_dir, "--count"],
        capture_output=True, text=True, timeout=120
    )
    output = proc.stdout + proc.stderr
    # Parse: look for "TOTAL: N warnings" or similar patterns
    m = re.search(r'total[:\s]+(\d+)\s+warning', output, re.IGNORECASE)
    if m:
        warnings_total = int(m.group(1))
    # Look for per-KLOC
    m2 = re.search(r'([\d.]+)\s+warnings?/KLOC', output, re.IGNORECASE)
    if m2:
        warnings_per_kloc = float(m2.group(1))
    elif warnings_total is not None and loc > 0:
        warnings_per_kloc = round(warnings_total / (loc / 1000), 2)
    # Parse lint breakdown lines: "  N  lint::name"
    for m3 in re.finditer(r'^\s*(\d+)\s+(clippy::\S+)', output, re.MULTILINE):
        lint_counts[m3.group(2)] = int(m3.group(1))
except subprocess.TimeoutExpired:
    rd_exit = -1
except FileNotFoundError:
    rd_exit = -2

entry = {
    "name": name,
    "version": version,
    "loc": loc,
    "warnings": warnings_total,
    "warnings_per_kloc": warnings_per_kloc,
    "lint_counts": lint_counts,
    "rd_exit": rd_exit,
    "analyzed": True,
}

if rd_exit not in (0, None):
    entry["error"] = f"rd_exit_{rd_exit}"

with open(result_file, 'w') as f:
    json.dump(entry, f, indent=2)

print(f"[result] {name}-{version}: {warnings_total} warnings, {warnings_per_kloc}/KLOC, {loc} LOC")
EOF

# Purge extracted source unless --keep-src
if [ "$KEEP_SRC" -eq 0 ]; then
    rm -rf "$EXTRACT_DIR"
    echo "[purge]  $NAME-$VERSION source removed"
fi

echo "[done]   $NAME-$VERSION → $RESULT_FILE"
