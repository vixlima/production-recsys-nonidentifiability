#!/usr/bin/env bash
# =============================================================================
# Runs one of the queries in sql/ against BigQuery.
#
#   ./scripts/run-sql.sh sql/dashboard-metrics.sql
#   ./scripts/run-sql.sh <file> --dry-run     # estimate cost only
#
# Substitutes the ${...} placeholders with the values in config.local.env
# (git-ignored) and runs each statement in sequence, with a ceiling on bytes
# billed to prevent an accidentally expensive query.
#
# The resolved SQL goes to a temporary file and is never version-controlled — it
# contains the real identifiers. That separation is what makes the queries in
# sql/ publishable at all.
#
# NOTE FOR READERS WITHOUT ACCESS: these queries are not executable outside the
# organisation that holds the data. This script is published so the execution
# path is auditable, and because the ceilings and guards below are part of the
# method rather than incidental tooling.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT}/config.local.env"
SQL_FILE="${1:-}"
MODE="${2:-}"

# Ceiling on bytes billed. Default 50 GB; override with MAX_BYTES=... on the call.
MAX_BYTES="${MAX_BYTES:-53687091200}"

if [[ -z "${SQL_FILE}" ]]; then
  echo "usage: $0 <path-to-sql> [--dry-run]" >&2
  exit 1
fi
if [[ ! -f "${SQL_FILE}" ]]; then
  echo "error: file not found: ${SQL_FILE}" >&2
  exit 1
fi
if [[ ! -f "${CONFIG}" ]]; then
  echo "error: ${CONFIG} not found." >&2
  echo "       cp config.example.env config.local.env  and fill in the values." >&2
  exit 1
fi
if ! command -v bq >/dev/null 2>&1; then
  echo "error: 'bq' not found. Install the Google Cloud SDK." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${CONFIG}"
set +a

# BSD mktemp only substitutes the Xs when they end the template: with a suffix
# after them it creates a file literally named "q-XXXXXX.sql", and two concurrent
# runs collide with "File exists". Without a suffix it works on both.
RESOLVED="$(mktemp "${TMPDIR:-/tmp}/q-XXXXXX")"
STATEMENTS="$(mktemp "${TMPDIR:-/tmp}/q-stmts-XXXXXX")"
trap 'rm -f "${RESOLVED}" "${STATEMENTS}"' EXIT

envsubst < "${SQL_FILE}" > "${RESOLVED}"

if grep -q 'FILL_IN' "${RESOLVED}"; then
  echo "error: unfilled placeholders remain in config.local.env" >&2
  grep -n 'FILL_IN' "${RESOLVED}" | head -5 >&2
  exit 1
fi

# Split into statements, discarding comments.
#
# Discarding only lines that START with `--` is not enough, and the defect is
# silent: because each statement is collapsed onto a single line, a comment at
# the end of one line comes to comment out the whole rest of the query. The
# symptom is a syntax error pointing somewhere unrelated to the cause.
#
# The cut respects quoted literals, because `--` inside a string is data, not a
# comment.
python3 - "${RESOLVED}" > "${STATEMENTS}" <<'PY'
import sys

def without_comment(line: str) -> str:
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in ("'", '"', "`"):
            quote = c
        elif c == "-" and line[i + 1 : i + 2] == "-":
            return line[:i]
        i += 1
    return line

text = open(sys.argv[1], encoding="utf-8").read()
lines = [without_comment(l) for l in text.splitlines()]
for stmt in "\n".join(lines).split(";"):
    if stmt.strip():
        print(" ".join(stmt.split()) + ";")
PY

# The project where the job is billed. It may differ from the project holding
# the tables: an account often has bigquery.jobs.create in only some projects but
# read access to the production tables. BigQuery allows that separation.
#
# --max_rows is mandatory, not a convenience: the default for `bq query` is **100
# rows**, and it truncates **silently**, with no warning and no error code. This
# once swallowed half of a 200-cell contingency table, and the loss surfaced only
# because a second fold came back empty and a division returned zero. Override
# with MAX_ROWS=... on the call.
MAX_ROWS="${MAX_ROWS:-100000}"
FLAGS=(--use_legacy_sql=false --maximum_bytes_billed="${MAX_BYTES}" --max_rows="${MAX_ROWS}" --format=prettyjson)
if [[ -n "${project_billing:-}" ]]; then
  FLAGS=(--project_id="${project_billing}" "${FLAGS[@]}")
fi
if [[ "${MODE}" == "--dry-run" ]]; then
  FLAGS+=(--dry_run)
  echo ">> estimate mode: nothing will be executed"
fi

TOTAL="$(wc -l < "${STATEMENTS}" | tr -d ' ')"
FAILURES=0
N=0
while IFS= read -r STATEMENT; do
  N=$((N + 1))
  echo ""
  echo "=============================================================="
  echo ">> query ${N}/${TOTAL}"
  echo "=============================================================="
  if ! bq query "${FLAGS[@]}" "${STATEMENT}"; then
    echo "!! query ${N} failed"
    FAILURES=$((FAILURES + 1))
  fi
done < "${STATEMENTS}"

echo ""
echo ">> done: ${N} query/queries, ${FAILURES} failure(s)."
[[ "${FAILURES}" -eq 0 ]]
