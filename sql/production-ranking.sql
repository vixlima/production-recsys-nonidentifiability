-- =============================================================================
-- The ranking metric over the whole history, and the price of censoring
-- =============================================================================
-- Produces: data/production-ranking-by-cutoff.csv
-- Supports: Figure 5, and the claim in Sections 4.3 and 5.2 that no ranking
--           value is interpretable without the cutoff that produced it
--
-- The production dashboard tracks F1, ROC-AUC, accuracy and precision:
-- CLASSIFICATION metrics, in a system that RANKS and truncates at five. The
-- criticism recorded elsewhere is that they measured the wrong family. This file
-- measures the right one, so that the criticism arrives with its alternative
-- attached.
--
-- WHAT ALREADY EXISTED, and what this file does NOT redo. An earlier measurement
-- computed the top-five win rate over **499 requests** with at least 25 closed
-- deals and at least one win. That selection remains valid and is not reproduced
-- here.
--
-- WHAT IS NEW, and it is two things:
--   (a) **NDCG@5**, which had never been computed over production. Precision in
--       the top five ignores position within the cutoff; NDCG does not. In a
--       system whose product is the order, the difference between the two is the
--       object itself.
--   (b) **Sensitivity to the censoring cutoff.** 69.4% of predictions have no
--       known outcome. Requiring 25 closed deals per request removes the bias at
--       the cost of retaining a handful of atypical requests. Varying the cutoff
--       shows the price instead of hiding it in a footnote.
--
-- UNIT OF ANALYSIS: the request, identified by `(tenant_id,
-- prediction_timestamp)`. **This is not the grid's grouping key**, which is
-- `(tenant_id, user_id, day)` — the prediction history does not carry `user_id`.
-- This measures what the production request produced, and is therefore the right
-- unit HERE; the grid's key governs a different experiment.
--
-- ORDERING: by the `rank` production itself recorded. It is the order the
-- salesperson saw, not a reconstruction — which avoids the tie-breaking defect
-- that has already inverted a result three times in this project.
--
-- BINARY RELEVANCE: `won = 1`. Rows without an outcome are REMOVED from the
-- list, not treated as losses — treating a missing outcome as a loss asserts
-- what is not known, and would bias downwards.
-- =============================================================================

-- Statement 1 — the structure of a request, before any metric.
-- Answers whether `rank` is a total order within the request. If it is not,
-- every ranking metric below would be ill-defined and this file is worthless.
WITH req AS (
  SELECT
    tenant_id, prediction_timestamp,
    COUNT(*)                       AS items,
    COUNT(DISTINCT rank)           AS distinct_ranks,
    MIN(rank)                      AS rank_min,
    MAX(rank)                      AS rank_max,
    COUNTIF(won IS NOT NULL)       AS resolved,
    COUNTIF(won = 1)               AS wins
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  GROUP BY tenant_id, prediction_timestamp
)
SELECT
  COUNT(*)                                          AS requests,
  SUM(items)                                        AS rows,
  COUNTIF(items = distinct_ranks)                   AS requests_with_unique_rank,
  COUNTIF(rank_min = 1)                             AS requests_starting_at_1,
  APPROX_QUANTILES(items, 4)                        AS quartiles_size,
  APPROX_QUANTILES(resolved, 4)                     AS quartiles_resolved,
  COUNTIF(wins = 0)                                 AS requests_without_a_win,
  COUNTIF(resolved = 0)                             AS requests_without_any_outcome,
  SAFE_DIVIDE(SUM(resolved), SUM(items))            AS fraction_resolved
FROM req;

-- Statement 2 — precision@5 and NDCG@5 by censoring cutoff.
-- The cutoff is the minimum number of deals WITH AN OUTCOME in the request. Each
-- output row is one cutoff, and the drop in request count is its price.
WITH resolved AS (
  SELECT tenant_id, prediction_timestamp, rank, won
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE won IS NOT NULL
),
lists AS (
  SELECT
    tenant_id, prediction_timestamp,
    COUNT(*)                                        AS n,
    SUM(won)                                        AS wins,
    ARRAY_AGG(won ORDER BY rank ASC LIMIT 5)        AS top
  FROM resolved
  GROUP BY tenant_id, prediction_timestamp
),
metrics AS (
  SELECT
    n, wins,
    -- precision@5: fraction of wins among the five first DISPLAYED
    SAFE_DIVIDE((SELECT SUM(w) FROM UNNEST(top) AS w), ARRAY_LENGTH(top)) AS p5,
    -- DCG@5 with log2(position+1) discount, position starting at 1
    (SELECT SUM(w / LOG(pos + 1, 2))
     FROM UNNEST(top) AS w WITH OFFSET AS o, UNNEST([o + 1]) AS pos)        AS dcg,
    -- IDCG@5: every win available in the top, up to five
    (SELECT SUM(1 / LOG(pos + 1, 2))
     FROM UNNEST(GENERATE_ARRAY(1, LEAST(wins, 5))) AS pos)                 AS idcg
  FROM lists
),
cutoffs AS (
  SELECT c AS cutoff FROM UNNEST([1, 5, 10, 25, 50]) AS c
)
SELECT
  c.cutoff                                                      AS min_resolved,
  COUNT(*)                                                      AS requests,
  COUNTIF(m.wins > 0)                                           AS requests_with_win,
  AVG(m.n)                                                      AS mean_resolved_items,
  AVG(SAFE_DIVIDE(m.wins, m.n))                                 AS mean_prevalence,
  AVG(m.p5)                                                     AS precision_at_5,
  -- NDCG is defined only where there is at least one win: with none, the ideal is zero
  AVG(IF(m.wins > 0, SAFE_DIVIDE(m.dcg, m.idcg), NULL))         AS ndcg_at_5
FROM metrics AS m
CROSS JOIN cutoffs AS c
WHERE m.n >= c.cutoff
GROUP BY c.cutoff
ORDER BY c.cutoff;
