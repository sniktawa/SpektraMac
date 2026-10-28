#!/usr/bin/env bash
# Times SpektraMac's renders and saves against a baseline: tools/benchmark.sh [--update].
#
# Measures the README's render times (spektra-cli benchmark) and, as #271 did, each save's time and
# peak memory footprint, GPU memory included (spektra-cli save, each in its own process under
# /usr/bin/time -l), on test photos it makes at those sizes. Each number is the best of $runs runs, so
# a busy Mac doesn't trip it. Compares them with tools/benchmark-baseline.tsv and exits 1, naming the
# row, when a time is more than 15 % slower or a peak more than 10 % higher. With --update, records
# them as the new baseline instead, with the Mac, macOS and commit they came from.
#
# The baseline is one Mac's: run it on that Mac, idle, before a pull request that touches the
# engine's speed or memory.
set -euo pipefail
export LC_ALL=C
repo=$(cd "$(dirname "$0")/.." && pwd)
baseline=$repo/tools/benchmark-baseline.tsv
runs=5
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "${1:-}" in
    --update) update=true ;;
    "") update=false ;;
    *) echo "usage: tools/benchmark.sh [--update]"; exit 2 ;;
esac

swift build -c release --package-path "$repo/Engine" > /dev/null
cli=$(swift build -c release --package-path "$repo/Engine" --show-bin-path)/spektra-cli
results=$work/results.tsv

# The smallest of the `label: N ms` lines' N on standard input (any digit grouping).
best_ms() { sed -n "s/^$1: \(.*\) ms$/\1/p" | tr -cd '0-9\n' | sort -n | head -1; }
# Adds a row (name, time, peak or -) to the results and shows it.
record() { printf '%s\t%s\t%s\n' "$@" | tee -a "$results"; }

echo "== Renders: spektra-cli benchmark, best of $runs runs"
for size in "2400 1600" "6000 4000" "6960 4640"; do
    read -r width height <<< "$size"
    photo=$work/photo.jpg
    "$cli" photo "$width" "$height" "$photo"
    for _ in $(seq "$runs"); do "$cli" benchmark "$photo"; done > "$work/renders.txt"
    record "Full render, $width × $height" "$(best_ms 'full render' < "$work/renders.txt")" -
    # The preview of a 2400 × 1600 photo is 1600 × 1067 (the engine's previewMaxSize).
    if [ "$width" = 2400 ]; then
        record "Preview, 1600 × 1067" "$(best_ms preview < "$work/renders.txt")" -
    fi
done

echo "== Saves: spektra-cli save under /usr/bin/time -l, each in its own process, best of $runs runs"
for size in "8660 5773 50" "12248 8165 100"; do
    read -r width height megapixels <<< "$size"
    photo=$work/photo.jpg
    "$cli" photo "$width" "$height" "$photo"
    for diffusion in none lens enlarger; do
        for _ in $(seq "$runs"); do
            if [ "$diffusion" = none ]; then
                /usr/bin/time -l "$cli" save "$photo" "$work/saved.jpg" 2>&1
            else
                /usr/bin/time -l "$cli" save "$photo" "$work/saved.jpg" "$diffusion" 2>&1
            fi
        done > "$work/saves.txt"
        label=$([ "$diffusion" = none ] && echo "no diffusion" || echo "$diffusion diffusion")
        peak=$(awk '/peak memory footprint/ { print int($1 / 1e6) }' "$work/saves.txt" | sort -n | head -1)
        record "Save $megapixels MP, $label" "$(best_ms save < "$work/saves.txt")" "$peak"
    done
done

if $update; then
    {
        echo "# tools/benchmark.sh's baseline: row, time (ms), peak memory footprint (MB, saves only)."
        echo "# $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) / 1073741824)) GB;" \
            "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)); commit $(git -C "$repo" rev-parse --short HEAD)"
        cat "$results"
    } > "$baseline"
    echo "== Recorded in tools/benchmark-baseline.tsv"
    exit 0
fi

echo "== Against tools/benchmark-baseline.tsv ($(sed -n 2p "$baseline" | cut -c 3-))"
awk -F '\t' '
    FNR == NR { if ($1 !~ /^#/) { time[$1] = $2; peak[$1] = $3 }; next }
    function compare(what, unit, base, now, limit) {
        change = (now - base) / base * 100
        printf "%8d %s → %8d %s  %+6.1f %%  %s%s\n", base, unit, now, unit, change, $1, what
        if (change > limit) { failed[++failures] = sprintf("%s%s: %+.1f %%, over %d %%", $1, what, change, limit) }
    }
    {
        if (!($1 in time)) { printf "not in the baseline: %s\n", $1; failed[++failures] = $1 " (not in the baseline)"; next }
        compare("", "ms", time[$1], $2, 15)
        if ($3 != "-") compare(" (peak)", "MB", peak[$1], $3, 10)
    }
    END {
        if (failures == 0) { print "== Within the baseline"; exit 0 }
        print "== Past the baseline:"
        for (i = 1; i <= failures; i++) print "   " failed[i]
        exit 1
    }
' "$baseline" "$results"
