#!/usr/bin/env python3
"""Generates the seven figures and three tables of the paper.

Reads only the published aggregates under `data/` — it does not touch BigQuery
and never sees an individual record. Each element declares in its caption the CSV
that produced it, so the figure carries its own provenance.

    python3 scripts/make_figures.py            # writes figures/ and tables.md
    python3 scripts/make_figures.py --list     # says what it would do

Palette: the first four colours pass the six checks of the palette validator in
light mode — luminance band, chroma floor, separation under colour-vision
deficiency (worst pair ΔE 9.2 deutan) and normal-vision floor (ΔE 16.3). The aqua
sits at 2.74 contrast against the surface, below 3:1, and the required relief is
direct labelling — which every figure with two or more series carries. Because
the paper will be printed, each series also gets its own dash pattern and marker:
identity never depends on colour alone.
"""

import argparse
import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
FIGS = ROOT / "figures"
TABLES = FIGS / "tables.md"

# validated palette — fixed order, never cycled
BLUE, ORANGE, AQUA, VIOLET = "#2a78d6", "#eb6834", "#1baf7a", "#4a3aa7"
INK = "#0b0b0b"
INK2 = "#52514e"
GRID = "#dcdcd8"

plt.rcParams.update({
    "font.size": 8.5,
    "axes.edgecolor": INK2,
    "axes.labelcolor": INK,
    "text.color": INK,
    "xtick.color": INK2,
    "ytick.color": INK2,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "figure.facecolor": "white",
    "axes.facecolor": "white",
})

WIDTH = 6.3          # single column, with slack
DPI = 200


def read(name):
    """Reads an aggregate, discarding the provenance line starting with '#'."""
    path = DATA / name
    with path.open(encoding="utf-8") as f:
        lines = [l for l in f if not l.startswith("#")]
    return list(csv.DictReader(lines)), path.name


def num(row, column):
    v = row.get(column, "")
    return float(v) if v not in ("", None) else None


def dec2(x, _=None):
    return f"{x:.2f}"


def dec3(x, _=None):
    return f"{x:.3f}"


def thousands(n):
    return f"{int(n):,}"


def short_month(iso):
    """2025-01-01 -> Jan 25."""
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    year, month, _ = iso.split("-")
    return f"{months[int(month) - 1]} {year[2:]}"


def frame(ax, title, ylabel, source=None, formatter=dec2):
    ax.set_title(title, fontsize=9.5, loc="left", pad=8, color=INK)
    ax.set_ylabel(ylabel, fontsize=8.5)
    ax.grid(axis="y", color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)
    ax.yaxis.set_major_formatter(FuncFormatter(formatter))
    if source:
        footer(ax, source)


# The source is NOT drawn inside the image. The typesetting emits it as a text
# element below the figure, and drawing it into the PNG as well would put the
# same information twice on the same page. The function stays, switched off,
# because a figure needs to carry its own provenance when seen outside the paper
# — flipping the constant is enough for that.
SOURCE_IN_FIGURE = False


def footer(ax, source, y=-0.52):
    """Data source, in axis fraction. Disabled by SOURCE_IN_FIGURE.

    Does not use `figure.text` at a fixed y: with rotated month labels the source
    line landed on top of them, which the first version of this figure did.
    """
    if not SOURCE_IN_FIGURE:
        return
    ax.annotate(f"source: {source}", xy=(0, y), xycoords="axes fraction",
                fontsize=6, color=INK2, annotation_clip=False)


def month_axis(ax, months):
    step = 2
    ax.set_xticks(range(0, len(months), step))
    ax.set_xticklabels([short_month(m) for m in months[::step]], rotation=45,
                       ha="right", fontsize=7)


def save(fig, name):
    FIGS.mkdir(parents=True, exist_ok=True)
    target = FIGS / name
    # atomic write: `format` is explicit because matplotlib does not recognise
    # the `.tmp` suffix
    tmp = target.with_name(target.name + ".tmp")
    fig.savefig(tmp, dpi=DPI, bbox_inches="tight", format="png")
    tmp.replace(target)
    plt.close(fig)
    return target


# ---------------------------------------------------------------------------
# F1 — the four dashboard metrics, month by month. Enters Section 2 as the state
# of the art of the operation, and is dismantled in 4.3: each point also measures
# the month's customer mix.
# ---------------------------------------------------------------------------
def f1():
    rows, source = read("dashboard-metrics-monthly.csv")
    months = [r["month"] for r in rows]
    series = [
        ("Accuracy", "accuracy", BLUE, "-", "o"),
        ("Precision", "precision", ORANGE, "--", "s"),
        ("Recall", "recall", AQUA, "-.", "^"),
        ("F1 at threshold 0.5", "f1_threshold_0_5", VIOLET, ":", "D"),
    ]
    fig, ax = plt.subplots(figsize=(WIDTH, 3.1))
    for label, column, colour, dash, marker in series:
        y = [num(r, column) for r in rows]
        ax.plot(range(len(months)), y, color=colour, linestyle=dash, marker=marker,
                markersize=3.4, linewidth=1.6, label=label)
    month_axis(ax, months)
    ax.set_ylim(0, 1)
    frame(ax, "The four metrics the operation tracks", "value", source)
    ax.legend(frameon=False, fontsize=7.5, ncol=4, loc="upper center",
              bbox_to_anchor=(0.5, -0.28))
    return save(fig, "f1-dashboard-metrics.png")


# ---------------------------------------------------------------------------
# F2 — the probability model against the combined score. Same metric, same axis.
# ---------------------------------------------------------------------------
def f2():
    rows, source = read("dashboard-metrics-monthly.csv")
    months = [r["month"] for r in rows]
    probability = [num(r, "auc_probability") for r in rows]
    score = [num(r, "auc_score") for r in rows]

    fig, ax = plt.subplots(figsize=(WIDTH, 3.1))
    ax.axhline(0.5, color=INK2, linewidth=0.9, linestyle=(0, (4, 3)))
    ax.text(len(months) - 0.4, 0.507, "chance", fontsize=7, color=INK2, ha="right")
    ax.plot(range(len(months)), probability, color=BLUE, marker="o", markersize=3.4,
            linewidth=1.6, label="Probability model")
    ax.plot(range(len(months)), score, color=ORANGE, linestyle="--", marker="s",
            markersize=3.4, linewidth=1.6, label="Combined score")
    month_axis(ax, months)
    worse = sum(1 for p, s in zip(probability, score)
                if s is not None and p is not None and s <= p)
    below = sum(1 for p in probability if p is not None and p < 0.5)
    frame(ax, "Monthly discrimination: the second model adds nothing",
          "area under the ROC curve", source)
    ax.legend(frameon=False, fontsize=7.5, ncol=2, loc="upper center",
              bbox_to_anchor=(0.5, -0.28))
    ax.annotate(f"score equal to or worse than the probability in {worse} of the "
                f"{len(months)} months; probability below chance in {below}",
                xy=(0, -0.62), xycoords="axes fraction", fontsize=6.5,
                color=INK2, annotation_clip=False)
    return save(fig, "f2-auc-probability-vs-score.png")


# ---------------------------------------------------------------------------
# F3 — the fine gradient, within the five displayed, and the coarse one, by rank
# band across three strata of prediction age.
# ---------------------------------------------------------------------------
def f3():
    bounds, source_a = read("censoring-bounds.csv")
    positions = [(int(r["key"]), num(r, "win_rate_at_position"))
                 for r in bounds if r["cutoff"] == "position"]
    bands, source_b = read("censoring-by-rank-and-age.csv")

    fig, (left, right) = plt.subplots(1, 2, figsize=(WIDTH, 2.9),
                                      gridspec_kw={"width_ratios": [1, 1.35]})

    left.plot([p for p, _ in positions], [w for _, w in positions], color=BLUE,
              marker="o", markersize=4.5, linewidth=1.8)
    for p, w in positions:
        left.annotate(dec3(w), (p, w), textcoords="offset points",
                      xytext=(0, 7), ha="center", fontsize=6.5, color=INK2)
    left.set_xticks([p for p, _ in positions])
    left.set_xlabel("displayed position", fontsize=8)
    left.set_ylim(0.22, 0.32)
    frame(left, "Within the top five", "win rate", None, dec3)

    strata = [
        ("up to 179 days", "i up to 179", BLUE, "-", "o"),
        ("180 to 364", "ii 180-364", ORANGE, "--", "s"),
        ("365 or more", "iii 365+ days", VIOLET, "-.", "^"),
    ]
    order = ["a 1-5 (displayed)", "b 6-10", "c 11-20", "d 21-50", "e 51+"]
    labels = ["1–5", "6–10", "11–20", "21–50", "51+"]
    for label, key, colour, dash, marker in strata:
        y = []
        for band in order:
            found = [r for r in bands
                     if r["prediction_age"] == key and r["rank_band"] == band]
            y.append(num(found[0], "win_rate_among_resolved") if found else None)
        right.plot(range(len(order)), y, color=colour, linestyle=dash, marker=marker,
                   markersize=4, linewidth=1.6, label=label)
    right.set_xticks(range(len(order)))
    right.set_xticklabels(labels, fontsize=7.5)
    right.set_xlabel("rank band", fontsize=8)
    # the two panels measure the same quantity over different bands, so each
    # declares its own axis — a shared scale would flatten the fine gradient,
    # which is the whole point of the left panel
    frame(right, "From top to tail, by prediction age", "win rate", None)
    right.legend(frameon=False, fontsize=7, title="prediction age",
                 title_fontsize=7, loc="lower left")
    fig.tight_layout()
    footer(left, f"{source_a} and {source_b}", y=-0.30)
    return save(fig, "f3-gradient-by-position-and-rank.png")


# ---------------------------------------------------------------------------
# F4 — the two ranking metrics by censoring cutoff, with prevalence alongside:
# without it the reader attributes to the system what is task difficulty.
# ---------------------------------------------------------------------------
def f4():
    rows, source = read("production-ranking-by-cutoff.csv")
    cutoffs = [r["min_resolved"] for r in rows]
    x = range(len(cutoffs))
    fig, ax = plt.subplots(figsize=(WIDTH, 3.0))
    for label, column, colour, dash, marker in [
        ("NDCG@5", "ndcg_at_5", BLUE, "-", "o"),
        ("Precision@5", "precision_at_5", ORANGE, "--", "s"),
        ("Mean prevalence", "mean_prevalence", AQUA, "-.", "^"),
    ]:
        y = [num(r, column) for r in rows]
        ax.plot(x, y, color=colour, linestyle=dash, marker=marker, markersize=4.2,
                linewidth=1.7, label=label)
        ax.annotate(dec3(y[0]), (0, y[0]), textcoords="offset points",
                    xytext=(-4, 4), ha="right", fontsize=6.5, color=colour)
        ax.annotate(dec3(y[-1]), (len(cutoffs) - 1, y[-1]),
                    textcoords="offset points", xytext=(5, -1), ha="left",
                    fontsize=6.5, color=colour)
    ax.set_xticks(list(x))
    ax.set_xticklabels(cutoffs)
    ax.set_xlabel("minimum deals with an outcome per request", fontsize=8)
    ax.set_xlim(-0.45, len(cutoffs) - 0.35)
    frame(ax, "Both metrics fall with the cutoff — and prevalence falls with them",
          "value", source, dec3)
    ax.legend(frameon=False, fontsize=7.5, ncol=3, loc="upper center",
              bbox_to_anchor=(0.5, -0.3))
    return save(fig, "f4-ranking-by-censoring-cutoff.png")


# ---------------------------------------------------------------------------
# F5 — the identification bounds. The central figure of the argument: the width
# of the interval is the message, not the point.
# ---------------------------------------------------------------------------
def f5():
    rows, source = read("censoring-bounds.csv")
    lines = [r for r in rows if r["p5_lower_bound"]]
    labels = {"all": "All requests", "2025": "2025", "2026": "2026"}

    fig, ax = plt.subplots(figsize=(WIDTH, 2.5))
    for i, r in enumerate(reversed(lines)):
        low, high = num(r, "p5_lower_bound"), num(r, "p5_upper_bound")
        observed, mar = num(r, "p5_observed"), num(r, "p5_mar")
        ax.plot([low, high], [i, i], color=GRID, linewidth=9, solid_capstyle="round",
                zorder=1)
        ax.plot([low, high], [i, i], color=INK2, linewidth=1.1, zorder=2)
        for x, colour, marker, label in [
                (low, INK2, "|", None), (high, INK2, "|", None),
                (mar, VIOLET, "s", "under ignorable missingness"),
                (observed, ORANGE, "o", "ignoring the censoring")]:
            ax.plot(x, i, marker=marker, color=colour, linestyle="none",
                    markersize=7 if marker != "|" else 11,
                    markeredgecolor="white", markeredgewidth=0.8 if marker != "|" else 0,
                    zorder=3, label=label if (label and i == len(lines) - 1) else None)
        ax.annotate(f"width {dec3(high - low)}", (high, i),
                    textcoords="offset points", xytext=(8, -2), fontsize=7,
                    color=INK2, va="center")
        ax.annotate(dec3(low), (low, i), textcoords="offset points",
                    xytext=(-6, -2), ha="right", fontsize=7, color=INK2, va="center")
    ax.set_yticks(range(len(lines)))
    ax.set_yticklabels([labels[r["key"]] for r in reversed(lines)], fontsize=8)
    ax.set_xlim(0, 0.95)
    ax.set_xlabel("true precision@5", fontsize=8)
    ax.xaxis.set_major_formatter(FuncFormatter(dec2))
    ax.grid(axis="x", color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)
    ax.set_title("The censored data does not identify the metric: it only bounds it",
                 fontsize=9.5, loc="left", pad=8, color=INK)
    ax.legend(frameon=False, fontsize=7.5, ncol=2, loc="upper center",
              bbox_to_anchor=(0.5, -0.32))
    fig.text(0.005, 0.005, f"source: {source}", fontsize=6, color=INK2)
    return save(fig, "f5-identification-bounds.png")


# ---------------------------------------------------------------------------
# F6 — customer concentration, month by month. Supports the claim that comparing
# two months compares two customer mixtures.
# ---------------------------------------------------------------------------
def f6():
    rows, source = read("customer-concentration-monthly.csv")
    months = [r["month"] for r in rows]
    fig, ax = plt.subplots(figsize=(WIDTH, 3.0))
    for label, column, colour, dash, marker in [
        ("Largest customer", "fraction_largest_customer", BLUE, "-", "o"),
        ("Three largest", "fraction_three_largest_customers", ORANGE, "--", "s"),
        ("Resolved from the largest", "fraction_resolved_largest_customer", VIOLET, "-.", "^"),
    ]:
        ax.plot(range(len(months)), [num(r, column) for r in rows], color=colour,
                linestyle=dash, marker=marker, markersize=3.4, linewidth=1.6,
                label=label)
    month_axis(ax, months)
    ax.set_ylim(0, 1)
    frame(ax, "Each month is a different mixture of customers",
          "fraction of the month's rows", source)
    ax.legend(frameon=False, fontsize=7.5, ncol=3, loc="upper center",
              bbox_to_anchor=(0.5, -0.28))
    return save(fig, "f6-customer-concentration.png")


# ---------------------------------------------------------------------------
# F7 — two defensible aggregations of the same data, with opposite conclusions
# about the direction of time. The fixed-mixture panel cannot be built.
# ---------------------------------------------------------------------------
def f7():
    rows, source = read("win-rate-series-two-aggregations.csv")
    months = [r["month"] for r in rows]
    fig, ax = plt.subplots(figsize=(WIDTH, 3.0))
    ax.plot(range(len(months)), [num(r, "weighted_raw") for r in rows],
            color=BLUE, marker="o", markersize=3.4, linewidth=1.7,
            label="Raw, weighted by size")
    ax.plot(range(len(months)), [num(r, "mean_of_means") for r in rows],
            color=ORANGE, linestyle="--", marker="s", markersize=3.4,
            linewidth=1.7, label="Mean of means across customers")
    month_axis(ax, months)
    balanced = [r for r in rows if r["balanced_panel"]]
    frame(ax, "Same data, two aggregations, opposite directions",
          "win rate among resolved", source, dec3)
    ax.legend(frameon=False, fontsize=7.5, ncol=2, loc="upper center",
              bbox_to_anchor=(0.5, -0.28))
    veterans = max(int(r["veterans_in_month"]) for r in rows)
    ax.annotate("the fixed-mixture panel does not sustain the series: it exists in "
                f"only {len(balanced)} of the {len(months)} months, and never with "
                f"more than {veterans} long-standing customer",
                xy=(0, -0.62), xycoords="axes fraction", fontsize=6.5,
                color=INK2, annotation_clip=False)
    return save(fig, "f7-win-rate-two-aggregations.png")


# ---------------------------------------------------------------------------
# The three tables, generated from the same aggregates.
# ---------------------------------------------------------------------------
def tables():
    parts = []

    rows, source = read("resolution-by-two-ages.csv")
    prediction_ages = ["1 prediction up to 179", "2 prediction 180-364", "3 prediction 365d+"]
    header = ["up to 179 days", "180 to 364", "365 or more"]
    # no Unicode arrow and no HTML entity: the header travels through pandoc to
    # pdflatex, which lacks those glyphs in the T1 encoding
    t1 = ["| Deal age (rows) by prediction age (columns) | " + " | ".join(header) + " |",
          "|---|---:|---:|---:|"]
    for age, label in [("i   up to 30d", "up to 30 days"), ("ii  31 to 90d", "31 to 90"),
                       ("iii 91 to 365d", "91 to 365"), ("iv  365d+", "over 365")]:
        cells = []
        for pa in prediction_ages:
            found = [r for r in rows
                     if r["deal_age"] == age and r["prediction_age"] == pa]
            cells.append(dec3(num(found[0], "resolution_rate")) if found else "—")
        t1.append(f"| {label} | " + " | ".join(cells) + " |")
    parts.append(("T1", "Resolution rate crossing the two ages", source, t1))

    weights, source2 = read("effective-score-weights.csv")
    p = {r["measure"]: float(r["value"]) for r in weights}
    t2 = [
        "| Alternative ranking | Top-5 identical to displayed | Mean overlap |",
        "|---|---:|---:|",
        f"| Probability alone | {dec3(p['fraction_top5_identical_to_probability'])} | "
        f"{dec3(p['mean_overlap_probability'])} |",
        f"| Uplift alone | {dec3(p['fraction_top5_identical_to_uplift'])} | "
        f"{dec3(p['mean_overlap_uplift'])} |",
    ]
    parts.append(("T2", "Overlap of the displayed top five with each term, over "
                        f"{thousands(p['requests_with_more_than_five'])} requests with "
                        "more than five items", source2, t2))

    t3 = [
        "| Term | Standard deviation | Correlation with the score | Distinct values |",
        "|---|---:|---:|---:|",
        f"| Uplift, nominal weight 0.3 | {dec3(p['sd_uplift_term'])} | "
        f"{dec3(p['corr_uplift_score'])} | {int(p['uplift_values'])} |",
        f"| Probability, nominal weight 0.7 | {dec3(p['sd_probability_term'])} | "
        f"{dec3(p['corr_probability_score'])} | {thousands(p['probability_values'])} |",
    ]
    parts.append(("T3", "Composition of the score: the term with the higher nominal "
                        "weight is the one that barely varies", source2, t3))

    out = ["<!-- generated by scripts/make_figures.py — do not edit by hand -->", ""]
    for key, caption, source_csv, lines in parts:
        out += [f"### {key} — {caption}", "", *lines, "", f"source: `{source_csv}`", ""]
    FIGS.mkdir(parents=True, exist_ok=True)
    tmp = TABLES.with_suffix(".md.tmp")
    tmp.write_text("\n".join(out), encoding="utf-8")
    tmp.replace(TABLES)
    return TABLES


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="writes nothing")
    args = ap.parse_args()

    elements = [("F1", f1), ("F2", f2), ("F3", f3), ("F4", f4),
                ("F5", f5), ("F6", f6), ("F7", f7)]
    if args.list:
        for key, _ in elements:
            print(f"{key} — would be written to {FIGS.relative_to(ROOT)}/")
        print(f"T1 to T3 — would be written to {TABLES.relative_to(ROOT)}")
        return

    missing = [n for n in ["dashboard-metrics-monthly.csv", "censoring-bounds.csv",
                           "censoring-by-rank-and-age.csv",
                           "production-ranking-by-cutoff.csv",
                           "customer-concentration-monthly.csv",
                           "win-rate-series-two-aggregations.csv",
                           "resolution-by-two-ages.csv",
                           "effective-score-weights.csv"]
               if not (DATA / n).exists()]
    if missing:
        sys.exit("missing aggregates: " + ", ".join(missing))

    for key, function in elements:
        target = function()
        print(f"{key}  {target.relative_to(ROOT)}  ({target.stat().st_size // 1024} KiB)")
    target = tables()
    print(f"T1–T3  {target.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
