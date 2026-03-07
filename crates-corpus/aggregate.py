#!/usr/bin/env python3
"""
aggregate.py — Aggregate per-crate JSON results into paper-ready statistics.

Usage:
    python3 aggregate.py [--results-dir ../results] [--output summary.json]

Reads all results/<name>-<version>.json files and computes:
  - Median/mean/P90 warnings/KLOC across analyzed crates
  - Pareto distribution of lint types across the corpus
  - Fraction of crates above/below the 18/KLOC threshold
  - Top-N lint types by total count
  - LaTeX table snippet for direct inclusion in the paper
"""

import argparse
import json
import os
import statistics
import sys
from collections import Counter
from pathlib import Path


def load_results(results_dir: Path) -> list[dict]:
    results = []
    for path in sorted(results_dir.glob("*.json")):
        try:
            with open(path) as f:
                entry = json.load(f)
            results.append(entry)
        except (json.JSONDecodeError, OSError) as e:
            print(f"WARNING: skipping {path.name}: {e}", file=sys.stderr)
    return results


def compute_stats(values: list[float]) -> dict:
    if not values:
        return {}
    values_sorted = sorted(values)
    n = len(values_sorted)
    p90_idx = int(0.9 * n)
    return {
        "n": n,
        "min": round(min(values_sorted), 2),
        "max": round(max(values_sorted), 2),
        "mean": round(statistics.mean(values_sorted), 2),
        "median": round(statistics.median(values_sorted), 2),
        "p90": round(values_sorted[min(p90_idx, n - 1)], 2),
        "stdev": round(statistics.stdev(values_sorted), 2) if n > 1 else 0.0,
    }


def pareto_table(lint_totals: Counter, top_n: int = 10) -> list[dict]:
    grand_total = sum(lint_totals.values())
    rows = []
    cumulative = 0
    for rank, (lint, count) in enumerate(lint_totals.most_common(top_n), start=1):
        cumulative += count
        rows.append({
            "rank": rank,
            "lint": lint,
            "count": count,
            "pct_of_total": round(100 * count / grand_total, 1) if grand_total else 0,
            "cumulative_pct": round(100 * cumulative / grand_total, 1) if grand_total else 0,
        })
    return rows


def latex_table(rows: list[dict]) -> str:
    lines = [
        r"\begin{tabular}{rlrrr}",
        r"  \toprule",
        r"  \textbf{Rank} & \textbf{Lint type} & \textbf{Count} & \textbf{\%} & \textbf{Cum.\%} \\",
        r"  \midrule",
    ]
    for row in rows:
        lint = row["lint"].replace("_", r"\_").replace("::", r"::")
        lines.append(
            f"  {row['rank']} & \\texttt{{{lint}}} & "
            f"{row['count']:,} & {row['pct_of_total']} & {row['cumulative_pct']} \\\\"
        )
    lines += [r"  \bottomrule", r"\end{tabular}"]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Aggregate corpus analysis results")
    parser.add_argument(
        "--results-dir",
        default=str(Path(__file__).parent.parent / "results"),
        help="Directory containing per-crate JSON result files",
    )
    parser.add_argument(
        "--output",
        default=str(Path(__file__).parent.parent / "summary.json"),
        help="Output path for aggregated summary JSON",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=18.0,
        help="warnings/KLOC threshold (default: 18.0)",
    )
    parser.add_argument(
        "--top-n",
        type=int,
        default=10,
        help="Number of top lint types to include in Pareto table",
    )
    parser.add_argument(
        "--latex",
        action="store_true",
        help="Print LaTeX table snippet to stdout",
    )
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    if not results_dir.exists():
        print(f"ERROR: results directory not found: {results_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Loading results from {results_dir}...", file=sys.stderr)
    all_results = load_results(results_dir)
    total_loaded = len(all_results)

    # Filter to successfully analyzed crates with valid data
    analyzed = [
        r for r in all_results
        if r.get("analyzed") and r.get("warnings_per_kloc") is not None
        and r.get("loc", 0) > 0
    ]
    errored = [r for r in all_results if r.get("error")]
    skipped = total_loaded - len(analyzed)

    print(f"  Total files:    {total_loaded}", file=sys.stderr)
    print(f"  Analyzed OK:    {len(analyzed)}", file=sys.stderr)
    print(f"  With errors:    {len(errored)}", file=sys.stderr)
    print(f"  Skipped/empty:  {skipped}", file=sys.stderr)

    # warnings/KLOC statistics
    densities = [r["warnings_per_kloc"] for r in analyzed]
    density_stats = compute_stats(densities)

    # Above/below threshold
    above = sum(1 for d in densities if d > args.threshold)
    below = len(densities) - above
    pct_above = round(100 * above / len(densities), 1) if densities else 0
    pct_below = round(100 * below / len(densities), 1) if densities else 0

    # Total LOC and warnings
    total_loc = sum(r.get("loc", 0) for r in analyzed)
    total_warnings = sum(r.get("warnings", 0) or 0 for r in analyzed)

    # Corpus-wide lint breakdown (Pareto)
    corpus_lints: Counter = Counter()
    for r in analyzed:
        for lint, count in (r.get("lint_counts") or {}).items():
            corpus_lints[lint] += count

    pareto_rows = pareto_table(corpus_lints, top_n=args.top_n)

    summary = {
        "corpus": {
            "total_crates_loaded": total_loaded,
            "total_crates_analyzed": len(analyzed),
            "total_crates_errored": len(errored),
            "total_loc": total_loc,
            "total_warnings": total_warnings,
            "corpus_warnings_per_kloc": round(total_warnings / (total_loc / 1000), 2)
            if total_loc > 0 else None,
        },
        "density_stats": density_stats,
        "threshold_analysis": {
            "threshold_kloc": args.threshold,
            "crates_above": above,
            "crates_below": below,
            "pct_above": pct_above,
            "pct_below": pct_below,
        },
        "pareto_top_lints": pareto_rows,
        "total_lint_instances": sum(corpus_lints.values()),
    }

    output_path = Path(args.output)
    with open(output_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"\nSummary written to {output_path}", file=sys.stderr)

    # Print human-readable summary
    print("\n=== Corpus Statistics ===")
    print(f"Crates analyzed:        {len(analyzed):,}")
    print(f"Total LOC:              {total_loc:,}")
    print(f"Total warnings:         {total_warnings:,}")
    if total_loc > 0:
        print(f"Corpus warnings/KLOC:   {summary['corpus']['corpus_warnings_per_kloc']:.2f}")
    print(f"\nWarnings/KLOC distribution:")
    print(f"  Median:  {density_stats.get('median', 'N/A')}")
    print(f"  Mean:    {density_stats.get('mean', 'N/A')}")
    print(f"  P90:     {density_stats.get('p90', 'N/A')}")
    print(f"  Min:     {density_stats.get('min', 'N/A')}")
    print(f"  Max:     {density_stats.get('max', 'N/A')}")
    print(f"\nThreshold ({args.threshold}/KLOC):")
    print(f"  Above:   {above:,} ({pct_above}%)")
    print(f"  Below:   {below:,} ({pct_below}%)")

    if pareto_rows:
        print(f"\nTop-{args.top_n} lint types (corpus-wide):")
        for row in pareto_rows:
            print(
                f"  {row['rank']:2d}. {row['lint']:<45s} "
                f"{row['count']:>8,}  ({row['pct_of_total']:5.1f}%  cum {row['cumulative_pct']:5.1f}%)"
            )

    if args.latex and pareto_rows:
        print("\n=== LaTeX Pareto Table ===")
        print(latex_table(pareto_rows))

    return 0


if __name__ == "__main__":
    sys.exit(main())
