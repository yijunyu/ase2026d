#!/usr/bin/env bash
# fetch-crates.sh — Download top-N crates from crates.io by download count
#
# Usage: ./fetch-crates.sh [N]   (default: 2669 to match Li et al. corpus)
#
# Output:
#   ../fetch/<name>-<version>.crate   — downloaded tarballs (skipped if exists)
#   ../corpus.json                    — index of all fetched crates
#   fetch-failures.log                — crates that failed to download
#
# Respects crates.io crawler policy: 1 req/sec, User-Agent header required.
# See: https://crates.io/policies

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
FETCH_DIR="$ROOT/fetch"
RESULTS_DIR="$ROOT/results"
FAILURE_LOG="$SCRIPT_DIR/fetch-failures.log"
CORPUS_JSON="$ROOT/corpus.json"

TARGET_N="${1:-2669}"
PER_PAGE=100
USER_AGENT="unleash-paper-corpus/0.1 (ASE 2026 research; contact: research@example.com)"

mkdir -p "$FETCH_DIR" "$RESULTS_DIR"

echo "[] Fetching top-$TARGET_N crates by downloads from crates.io..."
echo "[] Output: $FETCH_DIR"
echo ""

# Temporary index file (newline-delimited JSON objects)
TMP_INDEX="$SCRIPT_DIR/.corpus-index.ndjson"
> "$TMP_INDEX"
> "$FAILURE_LOG"

fetched=0
page=1

while [ "$fetched" -lt "$TARGET_N" ]; do
    echo "[page $page] Querying crates.io API..."
    API_URL="https://crates.io/api/v1/crates?per_page=$PER_PAGE&page=$page&sort=downloads"

    response=$(curl -sf \
        -H "User-Agent: $USER_AGENT" \
        -H "Accept: application/json" \
        "$API_URL") || {
        echo "ERROR: Failed to fetch page $page from crates.io API" >&2
        echo "page_$page" >> "$FAILURE_LOG"
        break
    }

    # Parse crates from response
    crate_count=$(echo "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
crates = data.get('crates', [])
print(len(crates))
")

    if [ "$crate_count" -eq 0 ]; then
        echo "[page $page] No more crates returned — stopping at $fetched crates."
        break
    fi

    # Process each crate on this page
    while IFS=$'\t' read -r name version downloads; do
        if [ "$fetched" -ge "$TARGET_N" ]; then
            break
        fi

        tarball_file="$FETCH_DIR/${name}-${version}.crate"

        if [ -f "$tarball_file" ]; then
            echo "  [skip] $name-$version (already downloaded)"
        else
            dl_url="https://static.crates.io/crates/${name}/${name}-${version}.crate"
            echo "  [fetch] $name-$version ($downloads downloads)..."
            if curl -sf \
                -H "User-Agent: $USER_AGENT" \
                -o "$tarball_file" \
                "$dl_url"; then
                echo "  [ok]   $name-$version ($(du -sh "$tarball_file" | cut -f1))"
            else
                echo "  [fail] $name-$version" | tee -a "$FAILURE_LOG"
                rm -f "$tarball_file"
                # Rate limit even on failure
                sleep 1
                continue
            fi
        fi

        # Record in index
        printf '%s\t%s\t%s\n' "$name" "$version" "$downloads" >> "$TMP_INDEX"
        fetched=$((fetched + 1))

        # Rate limit: 1 req/sec as required by crates.io policy
        sleep 1

    done < <(echo "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data.get('crates', []):
    name = c.get('id', '')
    version = c.get('newest_version', c.get('max_version', 'unknown'))
    downloads = c.get('downloads', 0)
    print(f'{name}\t{version}\t{downloads}')
")

    page=$((page + 1))
    # Rate limit between page fetches
    sleep 1
done

echo ""
echo "[] Fetched $fetched crates (target: $TARGET_N)"
echo "[] Building corpus.json index..."

python3 - "$TMP_INDEX" "$CORPUS_JSON" << 'EOF'
import json, sys, os

index_file = sys.argv[1]
output_file = sys.argv[2]

entries = []
with open(index_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split('\t')
        if len(parts) == 3:
            name, version, downloads = parts
            tarball = f"fetch/{name}-{version}.crate"
            entry = {
                "name": name,
                "version": version,
                "downloads": int(downloads),
                "tarball": tarball,
                "analyzed": False,
                "loc": None,
                "warnings": None,
                "warnings_per_kloc": None,
            }
            entries.append(entry)

with open(output_file, 'w') as f:
    json.dump({"crates": entries, "total": len(entries)}, f, indent=2)

print(f"Wrote {len(entries)} entries to {output_file}")
EOF

rm -f "$TMP_INDEX"

if [ -s "$FAILURE_LOG" ]; then
    fail_count=$(wc -l < "$FAILURE_LOG")
    echo "[] WARNING: $fail_count downloads failed — see $FAILURE_LOG"
fi

echo "[] Done. corpus.json written to $CORPUS_JSON"
