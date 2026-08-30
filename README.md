# Reproducibility artefact

Code and aggregates for *Three mechanisms of non-identifiability in the evaluation of production
recommender systems: a diagnostic framework and a case study*.

This repository contains **the code that produced every number in the paper and the aggregates
every number cites**. It does not contain the underlying data, and the reason is stated below
rather than left implicit.

---

## What reproduces exactly, and what does not

The chain of evidence has two halves, and only one of them fits in a public repository:

```
production data  →  SQL query  →  aggregate .csv  →  script  →  figure, table, number
└──── not included ────┘         └──────────── included ───────────────┘
```

**Reproduces exactly.** Everything from the aggregate onwards. Given the `.csv`, the scripts
regenerate the figure, the table and the number **byte for byte** — verified by double execution
with md5 comparison. Anyone can check any value in the paper without any access.

**Does not reproduce.** The half running from raw data to aggregate. The queries are here, complete
and readable, but they are not executable outside the organisation that holds the data.

## Why the data is not here

The object of study is the production history of a commercial CRM. Each record identifies a deal
belonging to a paying customer, and the operator's data handling policy forbids those records from
leaving. Section 3.6 of the paper develops this, and there is precedent in the same venue: an
interview study across four news organisations could not publish its transcripts, and an A/B test
report could share neither raw nor preprocessed data, reporting only rounded numbers.

**What synthetic data would buy, and what it would not.** A generator producing data of the same
shape would make this code runnable end to end by anyone — and would **not** demonstrate that the
results hold, because they depend on properties of the real data the generator would have to embed
in order to reproduce them. It would show that the code runs, not that the finding stands, and that
is how it would have to be described. So it is not included.

## Why the queries contain no identifiers

Every `.sql` file here is written with **placeholders** — `${project_insights}`,
`${dataset_recommendation}`, `${table_prediction_history}` — resolved at execution time by
`scripts/run-sql.sh` from a configuration file that is never version-controlled.
`config.example.env` documents what each field means and which project holds each dataset.

This is not sanitisation performed for publication. It is how the research repository has always
worked, because the rule that protects customer data also makes the code readable to someone who
does not know the infrastructure.

**The check is executable and refuses to publish.** The generator that produces this repository
reads the real values from the private configuration and searches for each one in every file that
would ship; if any appears, it names the file, **writes nothing** and exits non-zero. Two further
guards run alongside: no `.csv` above a line ceiling — the largest publishable aggregate has 80 data
rows, and a large file would signal accidental extraction — and the list of what ships is
**explicit and enumerated**, never a glob that grows on its own and publishes what nobody reviewed.

## Layout

| Path | Contents |
|---|---|
| `sql/` | The ten queries that produce the aggregates, parameterised |
| `scripts/` | Analysis and figure generation; the multiplicity correction; the retraction counter |
| `data/` | The thirteen aggregates supporting the figures, tables and numbers of the paper |
| `config.example.env` | Template for the identifiers, every field blank |

## Reproducing a number from the paper

Every figure and table declares its source aggregate in its own caption. The path is:

1. Find the aggregate named in the caption, under `data/`.
2. Its consuming script is in `scripts/`, and reads aggregates only — none of them touches a data
   warehouse or sees an individual record.
3. Run it. The output matches what is published.

Verifiable with no access at all:

```bash
python3 scripts/count_retractions.py      # the counts in Section 5.3
python3 scripts/make_figures.py           # the seven figures
```

## Aggregates are measurements, not fixtures

Each `.csv` is the output of a query over live data, and the corresponding execution date is
recorded in its header comment. Re-running the same query today returns slightly different numbers:
between two executions on the same day, the count of distinct requests went from 4,153 to 4,167.
Fractions move in the third decimal and absolute counts do not repeat. That is why every numerical
citation in the paper is dated, and why the aggregates ship with the paper rather than being
presented as re-executable.

## An honest limit

The part of the paper that would **most** need independent verification is precisely the part that
least admits it. The three mechanisms are checkable by any team over its own log — that is what
Section 4 proposes, and the queries here serve as templates — but the specific values depend on data
only the operator holds. What is offered in place of verification is traceability: every number has
a named source aggregate, an execution date and a volume read.

## Licence

Code under the MIT Licence; aggregates and documentation under CC BY 4.0. See `LICENSE`.

## Citation

Citation details will be added once the paper has a DOI.
