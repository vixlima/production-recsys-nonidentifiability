#!/usr/bin/env python3
"""Draws the synthesis figure of the diagnostic (Figure 3 of the paper): the three
quantities and what separates each pair.

The figure does NOT derive from an aggregate: it is a diagram, and the four
numbers annotated on it are the ones the paper reports, copied here in a declared
way — `auc-within-request.csv` (0.504), `censoring-bounds.csv` (0.0849 to 0.7508
and 33.41%) and `customer-concentration-monthly.csv` (0.093 to 0.718). None is
recomputed here. The paper's own script emits the figure in Portuguese and in
English; this artefact keeps the English one.

Usage: python3 scripts/make_synthesis_figure.py
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

ROOT = Path(__file__).resolve().parents[1]
NAME = "f8-synthesis-of-the-diagnostic.png"

TEXT = {
    "t1": ("θ₁ — what the dashboard estimates", "area under the ROC curve\nover the whole list",
           "in the case: 0.504 within the request"),
    "t2": ("θ₂ — what the decision requires", "fraction of won deals among\nthe five displayed positions",
           "in the case: between 0.0849 and 0.7508"),
    "t3": ("θ₃ — what the log allows", "the same fraction,\namong resolved deals",
           "in the case: 33.41% of displayed positions"),
    "m1": "mechanism 1\nfamily mismatch",
    "m2": "mechanism 2\ninformative censoring",
    "m3": "mechanism 3 — composition: the population over which each quantity is averaged\n"
          "in the case: the largest customer's share ranges from 0.093 to 0.718 across months",
    "test": "test",
    "tests": ("classify the metric by\nits value category",
              "resolved fraction and resolution\nrate by score band",
              "the metric under two\ndefensible aggregations"),
}


def draw(target: Path) -> None:
    t = TEXT
    fig, ax = plt.subplots(figsize=(10, 4.6), dpi=200)
    ax.set_xlim(0, 10); ax.set_ylim(0, 4.6); ax.axis("off")
    boxes = [(0.3, t["t1"]), (3.65, t["t2"]), (7.0, t["t3"])]
    for x, (title, desc, case) in boxes:
        ax.add_patch(FancyBboxPatch((x, 2.0), 2.7, 1.9, boxstyle="round,pad=0.05,rounding_size=0.15",
                                    linewidth=1.2, edgecolor="#333333", facecolor="#f4f4f4"))
        ax.text(x + 1.35, 3.62, title, ha="center", va="center", fontsize=9.5, fontweight="bold")
        ax.text(x + 1.35, 3.05, desc, ha="center", va="center", fontsize=8.6)
        ax.text(x + 1.35, 2.3, case, ha="center", va="center", fontsize=8.2, style="italic", color="#444444")
    for x0, x1, label in ((3.0, 3.65, t["m1"]), (6.35, 7.0, t["m2"])):
        ax.add_patch(FancyArrowPatch((x0, 2.95), (x1, 2.95), arrowstyle="<|-|>", mutation_scale=14,
                                     linewidth=1.2, color="#333333"))
        ax.text((x0 + x1) / 2, 3.35, label, ha="center", va="bottom", fontsize=7.8)
    # tests, below each box
    for x, test in zip((0.3, 3.65, 7.0), t["tests"]):
        ax.text(x + 1.35, 1.55, f"{t['test']}: {test}", ha="center", va="top", fontsize=7.6, color="#222222")
    # composition: a band across all three
    ax.add_patch(FancyBboxPatch((0.3, 0.15), 9.4, 0.75, boxstyle="round,pad=0.03,rounding_size=0.1",
                                linewidth=1.0, edgecolor="#333333", facecolor="#ffffff", linestyle="--"))
    ax.text(5.0, 0.525, t["m3"], ha="center", va="center", fontsize=7.8)
    fig.tight_layout()
    target.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(target, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    draw(ROOT / "figures" / NAME)
    print(f">> {NAME} written to figures/")


if __name__ == "__main__":
    main()
