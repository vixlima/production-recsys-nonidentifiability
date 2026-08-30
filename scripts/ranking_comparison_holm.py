#!/usr/bin/env python3
"""Applies the Holm-Bonferroni correction to the ranking comparison, as
pre-registered.

The pre-registration states that the system is superior to a baseline if "the
95% CI of the paired NDCG@5 difference per request excludes zero, with a
Holm-Bonferroni correction for the six comparisons". The query
`sql/ranking-comparison-by-customer.sql` produces the paired difference, the
standard error and the CI; this script applies the correction to the aggregate
it returns. It is what produces the `p` and `threshold` columns of Table 4.

The script KNOWS NO NUMBERS. It reads the CSV, sorts by p, applies Holm and
prints. Running it twice over the same CSV returns the same output — there is no
sampling here.

WHY HOLM AND NOT PLAIN BONFERRONI: it is what the pre-registration wrote, and
Holm is uniformly more powerful than Bonferroni at no cost in family-wise error
control. Note that the correction is **conservative for a conclusion of
superiority** and **anti-conservative for a conclusion of equality** — an
asymmetry the paper discusses. Here the conclusion at stake is superiority, so
correcting is the demanding side.

Usage:
    python3 scripts/ranking_comparison_holm.py data/ranking-comparison-preregistered.csv
    python3 scripts/ranking_comparison_holm.py <csv> --alpha 0.05

Expected columns, as the query names them:
    comparison, requests, mean_difference_ndcg5, standard_error, t
"""

from __future__ import annotations

import argparse
import csv
import math
import sys


def two_sided_p(t: float) -> float:
    """Two-sided p from the standard normal. With n in the hundreds, the
    difference against Student's t is in the fourth decimal and changes no
    decision here — but the approximation is declared rather than silenced."""
    return 2.0 * (1.0 - 0.5 * (1.0 + math.erf(abs(t) / math.sqrt(2.0))))


def holm(ps: list[float], alpha: float) -> list[bool]:
    """Holm-Bonferroni. Returns, in input order, whether each hypothesis is
    rejected.

    Sorts by ascending p and compares the i-th against alpha/(m-i). Stops at the
    first failure: from there on nothing is rejected, which is the step Holm adds
    to Bonferroni and what makes it more powerful.
    """
    m = len(ps)
    order = sorted(range(m), key=lambda i: ps[i])
    reject = [False] * m
    for position, i in enumerate(order):
        threshold = alpha / (m - position)
        if ps[i] <= threshold:
            reject[i] = True
        else:
            break
    return reject


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("csv", help="output of the cluster-robust query")
    ap.add_argument("--alpha", type=float, default=0.05)
    args = ap.parse_args()

    with open(args.csv, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    if not rows:
        print("!! empty CSV — nothing to correct", file=sys.stderr)
        return 1

    missing = {"comparison", "mean_difference_ndcg5", "standard_error", "t"} - set(rows[0])
    if missing:
        print(f"!! columns missing from the CSV: {sorted(missing)}", file=sys.stderr)
        return 1

    ts = [float(r["t"]) for r in rows]
    ps = [two_sided_p(t) for t in ts]
    rejected = holm(ps, args.alpha)
    m = len(rows)

    print(f"Ranking comparison under the pre-registered criterion — "
          f"Holm-Bonferroni, alpha = {args.alpha}, m = {m} comparisons\n")
    width = max(len(r["comparison"]) for r in rows)
    print(f"{'comparison':<{width}}  {'ΔNDCG@5':>9}  {'SE':>7}  {'t':>7}  "
          f"{'p':>9}  {'Holm threshold':>15}  verdict")
    for position, i in enumerate(sorted(range(m), key=lambda k: ps[k])):
        r = rows[i]
        threshold = args.alpha / (m - position)
        # Direction matters and cannot be omitted: the difference is system minus
        # alternative, so a negative t means the ALTERNATIVE wins. Labelling
        # everything that survives as "BETTER" would read the case where the
        # system loses backwards — and that is precisely the case of the tuned
        # baseline.
        if not rejected[i]:
            verdict = "not distinguishable from noise"
        elif float(r["mean_difference_ndcg5"]) > 0:
            verdict = "system BETTER"
        else:
            verdict = "system WORSE"
        print(f"{r['comparison']:<{width}}  {float(r['mean_difference_ndcg5']):>9.4f}  "
              f"{float(r['standard_error']):>7.4f}  {ts[i]:>7.3f}  {ps[i]:>9.2e}  "
              f"{threshold:>15.5f}  {verdict}")

    n_rejected = sum(rejected)
    print(f"\n{n_rejected} of {m} comparisons survive Holm.")
    print("For those that do not, the correct reading is that the difference is not")
    print("distinguishable from noise under this design — not that the rankings are equal.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
