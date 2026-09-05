-- =============================================================================
-- AUC within the request, and bounds on precision@5 and NDCG@5 under assumptions
-- =============================================================================
-- Produces: data/auc-within-request.csv, data/precision-bounds-under-assumption.csv,
--           data/ndcg5-bounds.csv
-- Supports: Section 5.1 (the within-request AUC of 0.568 and 0.504), Section 5.2
--           (the bounded-ratio family and the 0.214–0.481 interval for NDCG@5)
--           and Table 6
--
-- Written after an external review of the manuscript raised two points the text
-- could not answer without a new measurement:
--
-- 1. The monthly AUC of Section 3.1 POOLS predictions from distinct requests —
--    `dashboard-metrics.sql` partitions by month, not by request — while Section
--    4.1 of the same paper declares that scores from distinct requests are not
--    comparable. So "AUC close to 0.5" could be an artefact of the UNIT rather
--    than of the metric FAMILY. What separates the two is the AUC computed WITHIN
--    each request, over resolved deals, aggregated by request. Statement 1.
--
-- 2. `censoring-bounds.sql` gives only the two ends — assumption-free and under
--    ignorability given position — and the partial-identification literature
--    prescribes the middle: assumption by assumption, how much each narrows.
--    Statement 2 gives the family of bounds under a BOUNDED-RATIO assumption: the
--    win rate among censored positions is at most λ times the observed rate at
--    the same position. λ = 0 returns the floor; λ = 1 returns the MAR point of
--    `censoring-bounds.sql`; large λ returns the ceiling. And the paper reports
--    its central comparison in NDCG@5 without an identification interval for it:
--    statement 3 builds the floor and ceiling of the system's NDCG@5 over the
--    population of Table 4.
--
-- UNIT: the request, identified by (tenant_id, prediction_timestamp), as in
-- `censoring-bounds.sql`. No microdata leaves: every output is an aggregate.
-- =============================================================================

-- Statement 1 — AUC within the request, over resolved deals.
-- Only requests with at least one won AND one lost resolved deal enter, without
-- which the AUC is undefined. Three aggregations, because they decide different
-- things:
--   auc_mean_per_request   — equal weight per request (mean of the AUCs);
--   auc_pair_weighted      — concordant pairs summed over total pairs, which
--                            weights each request by its number of pairs;
--   auc_pooled             — the statistic `dashboard-metrics.sql` uses per
--                            month, here over ALL resolved deals together, for
--                            comparison.
WITH resolved AS (
  SELECT tenant_id, prediction_timestamp, won, score, classic_prediction
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE won IS NOT NULL AND score IS NOT NULL AND classic_prediction IS NOT NULL
),
ranks AS (
  SELECT
    tenant_id, prediction_timestamp, won,
    (RANK() OVER (PARTITION BY tenant_id, prediction_timestamp ORDER BY score)
     + COUNT(*) OVER (PARTITION BY tenant_id, prediction_timestamp) + 1
     - RANK() OVER (PARTITION BY tenant_id, prediction_timestamp ORDER BY score DESC)) / 2
      AS mid_rank_score,
    (RANK() OVER (PARTITION BY tenant_id, prediction_timestamp ORDER BY classic_prediction)
     + COUNT(*) OVER (PARTITION BY tenant_id, prediction_timestamp) + 1
     - RANK() OVER (PARTITION BY tenant_id, prediction_timestamp ORDER BY classic_prediction DESC)) / 2
      AS mid_rank_prob
  FROM resolved
),
per_request AS (
  SELECT
    tenant_id, prediction_timestamp,
    COUNT(*)                        AS resolved,
    SUM(won)                        AS won_deals,
    COUNT(*) - SUM(won)             AS lost_deals,
    -- Mann-Whitney: (sum of ranks of positives − n1(n1+1)/2) / (n1·n0)
    SUM(IF(won = 1, mid_rank_score, 0)) - SUM(won) * (SUM(won) + 1) / 2 AS concordant_score,
    SUM(IF(won = 1, mid_rank_prob, 0))  - SUM(won) * (SUM(won) + 1) / 2 AS concordant_prob,
    SUM(won) * (COUNT(*) - SUM(won))                                     AS pairs
  FROM ranks
  GROUP BY tenant_id, prediction_timestamp
),
eligible AS (
  SELECT * FROM per_request WHERE won_deals >= 1 AND lost_deals >= 1
),
pooled AS (
  SELECT
    SAFE_DIVIDE(
      SUM(IF(won = 1, r, 0)) - SUM(won) * (SUM(won) + 1) / 2,
      SUM(won) * (COUNT(*) - SUM(won))) AS auc_pooled_score
  FROM (
    SELECT won,
      (RANK() OVER (ORDER BY score) + COUNT(*) OVER () + 1 - RANK() OVER (ORDER BY score DESC)) / 2 AS r
    FROM resolved)
)
SELECT
  (SELECT COUNT(*) FROM per_request)                                  AS requests_with_resolved,
  COUNT(*)                                                            AS eligible_requests,
  SUM(resolved)                                                       AS resolved_in_eligible,
  AVG(resolved)                                                       AS resolved_per_request,
  AVG(SAFE_DIVIDE(concordant_score, pairs))                           AS auc_mean_per_request_score,
  SAFE_DIVIDE(SUM(concordant_score), SUM(pairs))                      AS auc_pair_weighted_score,
  AVG(SAFE_DIVIDE(concordant_prob, pairs))                            AS auc_mean_per_request_probability,
  SAFE_DIVIDE(SUM(concordant_prob), SUM(pairs))                       AS auc_pair_weighted_probability,
  COUNTIF(SAFE_DIVIDE(concordant_score, pairs) > 0.5)                 AS requests_auc_score_above_half,
  (SELECT auc_pooled_score FROM pooled)                               AS auc_pooled_score_all_resolved
FROM eligible;

-- Statement 2 — bounds on precision@5 under a bounded ratio, over requests with
-- five or more items (the same population as `censoring-bounds.sql`). The rate
-- per position is that of `censoring-bounds.sql`, over all rows with rank ≤ 5,
-- so that λ = 1 reproduces that query's MAR point. The imputed value is capped
-- at 1 per position, because a rate cannot exceed one; from the λ at which every
-- position saturates, the curve coincides with the ceiling.
WITH rate_per_position AS (
  SELECT rank, SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL)) AS p_win
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE rank <= 5
  GROUP BY rank
),
top AS (
  SELECT
    h.tenant_id, h.prediction_timestamp, h.won, t.p_win,
    COUNT(*) OVER (PARTITION BY h.tenant_id, h.prediction_timestamp) AS items_top5
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}` AS h
  JOIN rate_per_position AS t USING (rank)
  WHERE h.rank <= 5
),
per_request AS (
  SELECT
    tenant_id, prediction_timestamp, lambda,
    SAFE_DIVIDE(COUNTIF(won = 1) + SUM(IF(won IS NULL, LEAST(1.0, lambda * p_win), 0)), COUNT(*)) AS p5_under_bounded_ratio
  FROM top
  CROSS JOIN UNNEST([0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 100.0]) AS lambda
  WHERE items_top5 >= 5
  GROUP BY tenant_id, prediction_timestamp, lambda
)
SELECT
  lambda,
  COUNT(*)                        AS requests,
  AVG(p5_under_bounded_ratio)     AS p5_under_bounded_ratio
FROM per_request
GROUP BY lambda
ORDER BY lambda;

-- Statement 3 — floor and ceiling of the system's NDCG@5, on the population of
-- Table 4 of the paper: requests with at least 25 resolved deals and at least
-- one won deal, defined on the history (Table 4 defines them after the join with
-- the feature store, and the count may differ; the difference is reported, not
-- hidden). The floor treats every censored position as lost and the ceiling as
-- won, in the five displayed AND in the rest of the list, because the ideal
-- (IDCG) depends on how many won deals the whole list has. IDCG uses
-- LEAST(5, won deals in the list), as `ranking-comparison-by-customer.sql`.
WITH list AS (
  SELECT tenant_id, prediction_timestamp, rank, won
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
),
per_request AS (
  SELECT
    tenant_id, prediction_timestamp,
    COUNT(*)                                         AS items,
    COUNTIF(won IS NOT NULL)                         AS resolved,
    COUNTIF(won = 1)                                 AS won_observed,
    COUNTIF(won = 1) + COUNTIF(won IS NULL)          AS won_ceiling,
    SUM(IF(won = 1 AND rank <= 5, 1 / LOG(rank + 1, 2), 0))                       AS dcg_floor,
    SUM(IF((won = 1 OR won IS NULL) AND rank <= 5, 1 / LOG(rank + 1, 2), 0))      AS dcg_ceiling
  FROM list
  GROUP BY tenant_id, prediction_timestamp
  HAVING resolved >= 25 AND won_observed >= 1
),
with_idcg AS (
  SELECT *,
    (SELECT SUM(1 / LOG(i + 1, 2)) FROM UNNEST(GENERATE_ARRAY(1, LEAST(5, won_observed))) AS i) AS idcg_floor,
    (SELECT SUM(1 / LOG(i + 1, 2)) FROM UNNEST(GENERATE_ARRAY(1, LEAST(5, won_ceiling))) AS i)  AS idcg_ceiling
  FROM per_request
)
SELECT
  COUNT(*)                                                  AS requests,
  AVG(SAFE_DIVIDE(dcg_floor, idcg_floor))                   AS ndcg5_floor,
  AVG(SAFE_DIVIDE(dcg_ceiling, idcg_ceiling))               AS ndcg5_ceiling,
  AVG(SAFE_DIVIDE(dcg_ceiling, idcg_ceiling)) - AVG(SAFE_DIVIDE(dcg_floor, idcg_floor)) AS width,
  AVG(SAFE_DIVIDE(resolved, items))                         AS resolved_fraction_in_list
FROM with_idcg;
