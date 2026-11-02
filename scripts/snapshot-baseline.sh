#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
export SWIFTPM_CACHE_PATH="${SWIFTPM_CACHE_PATH:-/tmp/swiftpm-cache}"
swift build -c release --cache-path "$SWIFTPM_CACHE_PATH"
bin_dir="$(swift build -c release --cache-path "$SWIFTPM_CACHE_PATH" --show-bin-path)"
bin="$bin_dir/Winstripe"
out="${1:-.shots/baseline}"
mkdir -p "$out"

# Empty run directories avoid stale files being mistaken for current output.
for run in run1 run2; do
    if [[ -e "$out/$run" ]]; then
        echo "Output already exists: $out/$run. Choose a fresh output directory." >&2
        exit 1
    fi
done
for run in run1 run2; do
    "$bin" --snapshot-dir "$out/$run"
    "$bin" --dump-layout "$out/$run/layout.json"
    "$bin" --print-menu-geometry > "$out/$run/menu-geometry.txt"
done

list1="$(mktemp)"
list2="$(mktemp)"
trap 'rm -f "$list1" "$list2"' EXIT
(cd "$out/run1" && find . -type f | LC_ALL=C sort) > "$list1"
(cd "$out/run2" && find . -type f | LC_ALL=C sort) > "$list2"
different=0
if ! cmp -s "$list1" "$list2"; then
    echo "File lists differ:"
    diff -u "$list1" "$list2" || true
    different=1
fi
count=0
while IFS= read -r name; do
    count=$((count + 1))
    if [[ ! -f "$out/run2/$name" ]] || ! cmp -s "$out/run1/$name" "$out/run2/$name"; then
        echo "DIFF: ${name#./}"
        different=1
    fi
done < "$list1"
echo "Compared $count files (run2: $(wc -l < "$list2" | tr -d ' '))."
if [[ "$different" -ne 0 ]]; then
    exit 1
fi
echo "OK: all $count files are byte-identical."
