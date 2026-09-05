#!/usr/bin/env python3
"""Derives the retraction counts the paper cites, from the inventory.

Reads: data/retractions.csv
Supports: every count in Section 6.4 and in the fifth limitation of Section 6.2

    python3 scripts/count_retractions.py

WHY THIS SCRIPT EXISTS, and it is not tooling for its own sake. The paper cites
the counts in several places — thirty-eight claims overturned, twelve favouring
the audited system, one cause family accounting for more than a third. The
'against the central hypothesis' direction refers to the hypothesis of the wider
research programme, which the paper does not state, and is therefore not cited there. Counts written by hand go stale the moment the
inventory grows, and this project has watched that happen: on one occasion seven
mentions across two versions of the paper were out of date, **all of them correct
when they were written**. Deriving them from the table is what keeps prose and
inventory in agreement.

WHAT THE INVENTORY IS. Every claim of this work that the author's own
measurements overturned, each with the direction it moves in and the class of its
cause. It is evidence of procedure, not a confession: under confirmation bias,
twelve retractions favouring the audited object is not the distribution one would
expect from the person answering for it.

The direction values, and what each means for the reader:

    favours_system       the retraction favours the audited system
    against_system       it goes against the audited system
    against_hypothesis   it contradicts the central hypothesis of the work
    favours_hypothesis   it supports the central hypothesis
    neutral              neither
    against_researcher   it costs the researcher a prior expectation

The cause classes are lettered, and two of them matter most: **A**, measuring or
comparing over a unit of analysis that is not the declared one, and **H**,
transporting a measure from one population to another without checking that the
populations are the same. Together they are the family the paper reports as
concentrating more than a third of the entries — and the same family as the three
mechanisms of Section 5. The error the audit finds in the system is the error the
audit committed most.
"""

from __future__ import annotations

import collections
import csv
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "data" / "retractions.csv"

# The family the paper singles out. Declared here rather than inlined below, so
# that whoever changes it has to change one place and sees why it exists.
UNIT_OF_ANALYSIS_FAMILY = ("A", "H")


def main() -> int:
    if not INVENTORY.exists():
        print(f"!! inventory not found: {INVENTORY}", file=sys.stderr)
        return 1

    # Every aggregate in this repository carries a provenance line starting with
    # '#' above the header. It has to be dropped before the header is read, or
    # DictReader takes the comment for the column names.
    with INVENTORY.open(newline="", encoding="utf-8") as f:
        lines = [l for l in f if not l.startswith("#")]
    rows = list(csv.DictReader(lines))

    total = len(rows)
    by_direction = collections.Counter(r["direction"] for r in rows)
    by_class = collections.Counter(r["cause_class"] for r in rows if r["cause_class"])
    without_class = [r["id"] for r in rows if not r["cause_class"]]
    covered = total - len(without_class)
    family = [r for r in rows if r["cause_class"] in UNIT_OF_ANALYSIS_FAMILY]

    print(f"inventory: {INVENTORY.relative_to(ROOT)}")
    print(f"entries: {total}\n")

    print("direction:")
    for direction, n in by_direction.most_common():
        ids = [r["id"] for r in rows if r["direction"] == direction]
        print(f"  {direction:<20} {n:>3}   [{', '.join(ids)}]")

    print(f"\ncause classes: {len(by_class)} covering {covered} of {total}")
    for cause, n in by_class.most_common():
        ids = [r["id"] for r in rows if r["cause_class"] == cause]
        print(f"  {cause:<20} {n:>3}   [{', '.join(ids)}]")
    if without_class:
        print(f"  {'without a class':<20} {len(without_class):>3}   "
              f"[{', '.join(without_class)}]")

    pct = 100.0 * len(family) / total if total else 0.0
    print(f"\nfamily {'+'.join(UNIT_OF_ANALYSIS_FAMILY)} (unit of analysis): "
          f"{len(family)} of {total} = {pct:.1f}%")
    print(f"  entries: [{', '.join(r['id'] for r in family)}]")

    # The two numbers the paper leans on hardest, printed together because they
    # are the ones a reader checks first.
    print(f"\nas cited in the paper: {total} claims overturned; "
          f"{by_direction['favours_system']} favouring the audited system.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
