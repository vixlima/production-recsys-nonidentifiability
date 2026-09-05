#!/usr/bin/env python3
"""Fits the five-variable logistic regression the pre-registration specified.

Produces: data/logistic-baseline-coefficients.csv
Supports: the estimated comparator of Table 4 — the one that BEATS the system —, and
          the eighth limitation of Section 6.2

This closes the deviation in which the pre-registration listed, among the
baselines, "a logistic regression with five variables" that was never executed —
so that **no comparator was tuned**, and the seventh limitation of the paper
declared that as a property of the data when it is the consequence of a
deviation.

WHAT THIS SCRIPT DOES, in three steps:

1. Runs the contingency query, which returns the contingency table of the five
   discretised variables — one row per cell, with the total count and the count
   of wins, per cross-validation fold. **Only aggregates come down from
   BigQuery**; no individual record touches the local machine.

2. Fits **two** logistic regressions by iteratively reweighted least squares —
   IRLS, which is Newton-Raphson for the logistic model —, one per training fold.
   For predictors that are all categorical, the contingency table is a
   **sufficient statistic**: the weighted fit over cells is the same as the fit
   over rows, not an approximation. The implementation is pure NumPy, without
   scikit-learn, so the arithmetic is auditable line by line and does not depend
   on a library version.

3. Generates the evaluation SQL from a version-controlled template, injecting the
   coefficients as literals. The generated SQL scores each deal with the model of
   the **opposite** fold, so that no row is scored by a model that has seen it,
   and computes NDCG@5 per request, the paired difference against the system and
   the interval.

A NOTE ON WHY THIS COMPARATOR IS BIASED IN ITS OWN FAVOUR, since the paper turns
on it: the five attributes come from the CURRENT state of the deal, posterior to
the outcome, because the attribute base keeps no history. The system's order was
produced at the instant of prediction. The direction of that bias is known and
its magnitude is not measurable with this data. See Section 6.2, eighth
limitation.

Usage:
    python3 scripts/logistic_baseline.py               # run the query and fit
    python3 scripts/logistic_baseline.py --from-file <json>   # reuse saved output
"""

from __future__ import annotations

import argparse
import csv
import json
import pathlib
import re
import subprocess
import sys

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
SQL_CONTINGENCY = ROOT / "sql/logistic-contingency.sql"
TEMPLATE = ROOT / "sql/logistic-evaluation.sql.tpl"
SQL_GENERATED = ROOT / "sql/logistic-evaluation.sql"
CSV_COEF = ROOT / "data/logistic-baseline-coefficients.csv"

# Level order per variable. The FIRST of each list is the reference category, and
# the choice is declared rather than left to the accident of sort order: the most
# populous band of each variable was chosen, so that the coefficients are
# contrasts against the common case and not against a rare corner.
LEVELS = {
    "f_rating":       ["r1", "null", "r2", "r5", "other"],
    "f_stage":        ["null", "low", "medium", "high"],
    "f_inactivity":   ["recent_or_defect", "null", "medium", "long"],
    "f_interactions": ["i0_2", "i3_5", "i6_11", "i12_plus"],
    "f_value":        ["zero", "positive"],
}


def run_contingency() -> list[dict]:
    """Runs the query and returns the cells. Fails loudly: no data, no fit."""
    print(">> running", SQL_CONTINGENCY.name, file=sys.stderr)
    p = subprocess.run(
        [str(ROOT / "scripts/run-sql.sh"), str(SQL_CONTINGENCY.relative_to(ROOT))],
        cwd=ROOT, capture_output=True, text=True,
    )
    if p.returncode != 0:
        print(p.stdout[-3000:], file=sys.stderr)
        raise SystemExit("!! the query failed")
    m = re.search(r"\[\s*\{.*\}\s*\]", p.stdout, re.S)
    if not m:
        raise SystemExit("!! no JSON found in the query output")
    return json.loads(m.group(0))


def design_matrix(cells: list[dict]) -> tuple[np.ndarray, np.ndarray, np.ndarray, list[str]]:
    """Builds X with dummies, plus the vectors of successes and totals per cell."""
    names = ["intercept"]
    for var, levels in LEVELS.items():
        names += [f"{var}={l}" for l in levels[1:]]  # the first is the reference

    X, successes, totals = [], [], []
    for c in cells:
        row = [1.0]
        for var, levels in LEVELS.items():
            value = c[var]
            if value not in levels:
                raise SystemExit(f"!! unexpected band in {var}: {value!r}")
            row += [1.0 if value == l else 0.0 for l in levels[1:]]
        X.append(row)
        successes.append(float(c["wins"]))
        totals.append(float(c["n"]))
    return np.array(X), np.array(successes), np.array(totals), names


def fit(X: np.ndarray, successes: np.ndarray, totals: np.ndarray,
        max_iter: int = 100, tol: float = 1e-10) -> np.ndarray:
    """IRLS for the grouped binomial logistic model. Returns the coefficients.

    Unregularised, deliberately: the model has fifteen parameters against
    nineteen thousand observations per fold, and regularising would introduce a
    choice of penalty strength that the pre-registration did not declare.
    """
    beta = np.zeros(X.shape[1])
    for _ in range(max_iter):
        eta = X @ beta
        mu = 1.0 / (1.0 + np.exp(-eta))
        w = totals * mu * (1.0 - mu)
        w = np.maximum(w, 1e-12)          # a saturated cell must not stall the iteration
        z = eta + (successes - totals * mu) / w
        WX = X * w[:, None]
        new_beta = np.linalg.solve(X.T @ WX + 1e-10 * np.eye(X.shape[1]), WX.T @ z)
        if np.max(np.abs(new_beta - beta)) < tol:
            return new_beta
        beta = new_beta
    print(f"!! IRLS did not converge in {max_iter} iterations", file=sys.stderr)
    return beta


def deviance(X, successes, totals, beta) -> float:
    """Residual deviance, recorded so the fit is shown to be sensible."""
    mu = np.clip(1.0 / (1.0 + np.exp(-(X @ beta))), 1e-12, 1 - 1e-12)
    observed, failures = successes, totals - successes
    with np.errstate(divide="ignore", invalid="ignore"):
        t1 = np.where(observed > 0, observed * np.log(observed / (totals * mu)), 0.0)
        t2 = np.where(failures > 0, failures * np.log(failures / (totals * (1 - mu))), 0.0)
    return float(2 * np.sum(t1 + t2))


def score_sql(beta: np.ndarray, names: list[str], suffix: str) -> str:
    """Translates the coefficients into a SQL linear-score expression."""
    by_name = dict(zip(names, beta))
    parts = [f"{by_name['intercept']:.10f}"]
    for var, levels in LEVELS.items():
        col = var.replace("f_", "band_")
        cases = " ".join(
            f"WHEN {col} = '{l}' THEN {by_name[f'{var}={l}']:.10f}" for l in levels[1:]
        )
        parts.append(f"(CASE {cases} ELSE 0.0 END)")
    return f"    -- linear score of the model trained on fold {suffix}\n    " + \
           "\n    + ".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--from-file", help="JSON already saved from the contingency query")
    args = ap.parse_args()

    cells = (json.loads(pathlib.Path(args.from_file).read_text())
             if args.from_file else run_contingency())

    print(f">> {len(cells)} cells")
    fits: dict[int, np.ndarray] = {}
    csv_rows = []
    for fold in (0, 1):
        subset = [c for c in cells if int(c["fold"]) == fold]
        X, successes, totals, names = design_matrix(subset)
        beta = fit(X, successes, totals)
        fits[fold] = beta
        n, wins = int(totals.sum()), int(successes.sum())
        print(f"   fold {fold}: {len(subset)} cells, n={n:,}, wins={wins:,}, "
              f"prevalence={wins/n:.4f}, residual deviance="
              f"{deviance(X, successes, totals, beta):.1f}")
        for name, value in zip(names, beta):
            csv_rows.append({"training_fold": fold, "term": name,
                             "coefficient": round(float(value), 6),
                             "odds_ratio": round(float(np.exp(value)), 6)})

    CSV_COEF.parent.mkdir(parents=True, exist_ok=True)
    with CSV_COEF.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(csv_rows[0]))
        w.writeheader(); w.writerows(csv_rows)
    print(f">> coefficients written to {CSV_COEF.relative_to(ROOT)}")

    # fold 0 is SCORED by the model trained on fold 1, and vice versa
    if TEMPLATE.exists():
        template = TEMPLATE.read_text()
        generated = (template
                     .replace("{{SCORE_FOR_FOLD_0}}", score_sql(fits[1], names, "1"))
                     .replace("{{SCORE_FOR_FOLD_1}}", score_sql(fits[0], names, "0")))
        SQL_GENERATED.write_text(generated)
        print(f">> SQL generated at {SQL_GENERATED.relative_to(ROOT)}")

    print("\nCoefficients, training fold 0:")
    for name, value in zip(names, fits[0]):
        print(f"   {name:34s} {value:+8.4f}   OR={np.exp(value):6.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
