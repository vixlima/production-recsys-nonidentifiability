-- =============================================================================
-- The ranking comparison by the criterion the pre-registration declared, paired by request
-- =============================================================================
-- Produces: data/ranking-comparison-preregistered.csv (23 August 2026) and
--           data/ranking-comparison-preregistered-2026-09-05.csv (5 September 2026)
-- Supports: the by-request columns of Table 2, and the by-request side of Table 3
--
-- The pre-registration declares: "the system is considered superior to a
-- baseline if the 95% CI of the paired NDCG@5 difference per request excludes
-- zero, with Holm-Bonferroni correction for the comparisons."
--
-- DESIGN, and every choice is inherited from the original finding so that the
-- comparison is between COMPUTATIONS and not between designs:
--   * same cut: requests with >= 25 closed deals and >= 1 won deal;
--   * same declared tie-break, by FARM_FINGERPRINT, in every baseline;
--   * the system ranks by the displayed `rank`, never recomputed from the score;
--   * same attribute source: the CURRENT feature store, not the state at
--     prediction time. Inherited limitation, not removable here (the paper's
--     eighth limitation).
--
-- The unit of the test is the NDCG@5 difference WITHIN the request, and the
-- interval comes from a paired bootstrap resampling REQUESTS, with the seed
-- declared in the code. The resampling unit the pre-registration declares is the
-- customer; that estimator is `ranking-comparison-by-customer.sql`, and this query
-- is reported alongside it as the by-request sensitivity.
--
-- OUTPUT: aggregates only. No request row leaves BigQuery — the bootstrap runs
-- inside, and what comes down is one row per comparison. The Holm-Bonferroni
-- correction is applied on this aggregate by `ranking_comparison_holm.py`.
--
-- Bootstrap SEED: `replicate * 1000003 + FARM_FINGERPRINT(key)`, a declared
-- prime, deterministic. Two executions return the same result.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. NDCG@5 PER REQUEST AND PER RANKING, PAIRED DIFFERENCE AGAINST THE SYSTEM
-- -----------------------------------------------------------------------------
-- Returns, per comparison: n, the mean paired NDCG@5 difference, the standard
-- error, the t, and the analytic 95% CI. The bootstrap CI comes from Q2.

WITH closed AS (
  SELECT
    h.tenant_id, h.prediction_timestamp, h.deal_id,
    h.rank, h.won = 1 AS won_deal
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}` h
  WHERE h.deal_status = 'closed'
),

request AS (
  SELECT tenant_id, prediction_timestamp, COUNTIF(won_deal) AS won_deals
  FROM closed
  GROUP BY tenant_id, prediction_timestamp
  HAVING COUNT(*) >= 25 AND COUNTIF(won_deal) >= 1
),

attribute AS (
  SELECT
    deal_id,
    ANY_VALUE(rating)             AS rating,
    ANY_VALUE(deal_stage_order)   AS deal_stage_order,
    ANY_VALUE(stage_score_tenant) AS stage_score_tenant,
    ANY_VALUE(inactivity_time)    AS inactivity_time,
    ANY_VALUE(interactions)       AS interactions,
    ANY_VALUE(amount_monthly)     AS amount_monthly
  FROM `${project_insights}.${dataset_recommendation}.${table_feature_store}`
  GROUP BY deal_id
),

base AS (
  SELECT f.*, r.won_deals AS won_in_request, a.* EXCEPT (deal_id)
  FROM closed f
  JOIN request r USING (tenant_id, prediction_timestamp)
  JOIN attribute a USING (deal_id)
),

ranked AS (
  SELECT tenant_id, prediction_timestamp, won_deal, won_in_request,
    ROW_NUMBER() OVER (w ORDER BY rank               ASC)                             AS pos_system,
    ROW_NUMBER() OVER (w ORDER BY rating             DESC, FARM_FINGERPRINT(deal_id)) AS pos_qualification,
    ROW_NUMBER() OVER (w ORDER BY deal_stage_order   DESC, FARM_FINGERPRINT(deal_id)) AS pos_stage,
    ROW_NUMBER() OVER (w ORDER BY stage_score_tenant DESC, FARM_FINGERPRINT(deal_id)) AS pos_stage_score,
    ROW_NUMBER() OVER (w ORDER BY inactivity_time    ASC,  FARM_FINGERPRINT(deal_id)) AS pos_recency,
    ROW_NUMBER() OVER (w ORDER BY interactions       DESC, FARM_FINGERPRINT(deal_id)) AS pos_interactions,
    ROW_NUMBER() OVER (w ORDER BY amount_monthly     DESC, FARM_FINGERPRINT(deal_id)) AS pos_value,
    ROW_NUMBER() OVER (w ORDER BY FARM_FINGERPRINT(deal_id))                          AS pos_random
  FROM base
  WINDOW w AS (PARTITION BY tenant_id, prediction_timestamp)
),

-- NDCG@5 per request and per criterion. The IDCG uses LEAST(5, won_in_request),
-- because the best possible ranker puts at the top as many won deals as exist in
-- the request, up to five.
ndcg AS (
  SELECT
    tenant_id, prediction_timestamp,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_system        <= 5, 1/LOG(pos_system+1,2),        0)), idcg) AS n_system,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_qualification <= 5, 1/LOG(pos_qualification+1,2), 0)), idcg) AS n_qualification,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_stage         <= 5, 1/LOG(pos_stage+1,2),         0)), idcg) AS n_stage,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_stage_score   <= 5, 1/LOG(pos_stage_score+1,2),   0)), idcg) AS n_stage_score,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_recency       <= 5, 1/LOG(pos_recency+1,2),       0)), idcg) AS n_recency,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_interactions  <= 5, 1/LOG(pos_interactions+1,2),  0)), idcg) AS n_interactions,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_value         <= 5, 1/LOG(pos_value+1,2),         0)), idcg) AS n_value,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_random        <= 5, 1/LOG(pos_random+1,2),        0)), idcg) AS n_random
  FROM (
    SELECT *,
      (SELECT SUM(1/LOG(i+1,2))
       FROM UNNEST(GENERATE_ARRAY(1, LEAST(5, won_in_request))) AS i) AS idcg
    FROM ranked
  )
  GROUP BY tenant_id, prediction_timestamp, idcg
),

diff AS (
  SELECT 'system - qualification'   AS comparison, tenant_id, prediction_timestamp, n_system - n_qualification AS d FROM ndcg
  UNION ALL SELECT 'system - stage',        tenant_id, prediction_timestamp, n_system - n_stage        FROM ndcg
  UNION ALL SELECT 'system - stage_score',  tenant_id, prediction_timestamp, n_system - n_stage_score  FROM ndcg
  UNION ALL SELECT 'system - recency',      tenant_id, prediction_timestamp, n_system - n_recency      FROM ndcg
  UNION ALL SELECT 'system - interactions', tenant_id, prediction_timestamp, n_system - n_interactions FROM ndcg
  UNION ALL SELECT 'system - value',        tenant_id, prediction_timestamp, n_system - n_value        FROM ndcg
  UNION ALL SELECT 'system - random',       tenant_id, prediction_timestamp, n_system - n_random       FROM ndcg
)

SELECT
  comparison,
  COUNT(*)                                                        AS requests,
  ROUND(AVG(d), 4)                                                AS mean_difference_ndcg5,
  ROUND(STDDEV(d) / SQRT(COUNT(*)), 4)                            AS standard_error,
  ROUND(SAFE_DIVIDE(AVG(d), STDDEV(d) / SQRT(COUNT(*))), 3)       AS t,
  ROUND(AVG(d) - 1.96 * STDDEV(d) / SQRT(COUNT(*)), 4)            AS ci95_low_analytic,
  ROUND(AVG(d) + 1.96 * STDDEV(d) / SQRT(COUNT(*)), 4)            AS ci95_high_analytic
FROM diff
GROUP BY comparison
ORDER BY t DESC;


-- -----------------------------------------------------------------------------
-- Q2. 95% CI BY PAIRED BOOTSTRAP, RESAMPLING REQUESTS
-- -----------------------------------------------------------------------------
-- One thousand replicates. In each, the same number of requests is drawn with
-- replacement and the mean difference is recomputed — paired, because a drawn
-- request enters with its eight rankings together.
--
-- The resampling is deterministic: replicate r picks, for each position i, the
-- request with index `MOD(ABS(FARM_FINGERPRINT(CAST(r*1000003+i AS STRING))), n)`.
-- No RAND(), on purpose: RAND() is not reproducible across executions.

WITH closed AS (
  SELECT h.tenant_id, h.prediction_timestamp, h.deal_id, h.rank, h.won = 1 AS won_deal
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}` h
  WHERE h.deal_status = 'closed'
),
request AS (
  SELECT tenant_id, prediction_timestamp, COUNTIF(won_deal) AS won_deals
  FROM closed
  GROUP BY tenant_id, prediction_timestamp
  HAVING COUNT(*) >= 25 AND COUNTIF(won_deal) >= 1
),
attribute AS (
  SELECT deal_id,
    ANY_VALUE(rating) AS rating, ANY_VALUE(deal_stage_order) AS deal_stage_order,
    ANY_VALUE(stage_score_tenant) AS stage_score_tenant,
    ANY_VALUE(inactivity_time) AS inactivity_time,
    ANY_VALUE(interactions) AS interactions, ANY_VALUE(amount_monthly) AS amount_monthly
  FROM `${project_insights}.${dataset_recommendation}.${table_feature_store}`
  GROUP BY deal_id
),
base AS (
  SELECT f.*, r.won_deals AS won_in_request, a.* EXCEPT (deal_id)
  FROM closed f
  JOIN request r USING (tenant_id, prediction_timestamp)
  JOIN attribute a USING (deal_id)
),
ranked AS (
  SELECT tenant_id, prediction_timestamp, won_deal, won_in_request,
    ROW_NUMBER() OVER (w ORDER BY rank               ASC)                             AS pos_system,
    ROW_NUMBER() OVER (w ORDER BY rating             DESC, FARM_FINGERPRINT(deal_id)) AS pos_qualification,
    ROW_NUMBER() OVER (w ORDER BY deal_stage_order   DESC, FARM_FINGERPRINT(deal_id)) AS pos_stage,
    ROW_NUMBER() OVER (w ORDER BY stage_score_tenant DESC, FARM_FINGERPRINT(deal_id)) AS pos_stage_score,
    ROW_NUMBER() OVER (w ORDER BY inactivity_time    ASC,  FARM_FINGERPRINT(deal_id)) AS pos_recency,
    ROW_NUMBER() OVER (w ORDER BY interactions       DESC, FARM_FINGERPRINT(deal_id)) AS pos_interactions,
    ROW_NUMBER() OVER (w ORDER BY amount_monthly     DESC, FARM_FINGERPRINT(deal_id)) AS pos_value,
    ROW_NUMBER() OVER (w ORDER BY FARM_FINGERPRINT(deal_id))                          AS pos_random
  FROM base
  WINDOW w AS (PARTITION BY tenant_id, prediction_timestamp)
),
ndcg AS (
  SELECT tenant_id, prediction_timestamp,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_system        <= 5, 1/LOG(pos_system+1,2),        0)), idcg) AS n_system,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_qualification <= 5, 1/LOG(pos_qualification+1,2), 0)), idcg) AS n_qualification,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_stage         <= 5, 1/LOG(pos_stage+1,2),         0)), idcg) AS n_stage,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_stage_score   <= 5, 1/LOG(pos_stage_score+1,2),   0)), idcg) AS n_stage_score,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_recency       <= 5, 1/LOG(pos_recency+1,2),       0)), idcg) AS n_recency,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_interactions  <= 5, 1/LOG(pos_interactions+1,2),  0)), idcg) AS n_interactions,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_value         <= 5, 1/LOG(pos_value+1,2),         0)), idcg) AS n_value,
    SAFE_DIVIDE(SUM(IF(won_deal AND pos_random        <= 5, 1/LOG(pos_random+1,2),        0)), idcg) AS n_random
  FROM (
    SELECT *, (SELECT SUM(1/LOG(i+1,2))
               FROM UNNEST(GENERATE_ARRAY(1, LEAST(5, won_in_request))) AS i) AS idcg
    FROM ranked
  )
  GROUP BY tenant_id, prediction_timestamp, idcg
),
-- dense index of the requests, for the draw with replacement
indexed AS (
  SELECT *, ROW_NUMBER() OVER (ORDER BY FARM_FINGERPRINT(
              CONCAT(CAST(tenant_id AS STRING), CAST(prediction_timestamp AS STRING)))) - 1 AS idx
  FROM ndcg
),
size AS (SELECT COUNT(*) AS n FROM indexed),
draw AS (
  SELECT r AS replicate,
         MOD(ABS(FARM_FINGERPRINT(CAST(r * 1000003 + i AS STRING))), (SELECT n FROM size)) AS idx
  FROM UNNEST(GENERATE_ARRAY(1, 1000)) AS r,
       UNNEST(GENERATE_ARRAY(0, (SELECT n FROM size) - 1)) AS i
),
replicate_diff AS (
  SELECT s.replicate,
    AVG(x.n_system - x.n_qualification) AS d_qualification,
    AVG(x.n_system - x.n_stage)         AS d_stage,
    AVG(x.n_system - x.n_stage_score)   AS d_stage_score,
    AVG(x.n_system - x.n_recency)       AS d_recency,
    AVG(x.n_system - x.n_interactions)  AS d_interactions,
    AVG(x.n_system - x.n_value)         AS d_value,
    AVG(x.n_system - x.n_random)        AS d_random
  FROM draw s JOIN indexed x USING (idx)
  GROUP BY s.replicate
),
long AS (
  SELECT * FROM replicate_diff
  UNPIVOT (d FOR comparison IN (
    d_qualification, d_stage, d_stage_score, d_recency,
    d_interactions, d_value, d_random))
)
SELECT
  comparison,
  COUNT(*)                                                     AS replicates,
  ROUND(AVG(d), 4)                                             AS mean_difference_bootstrap,
  ROUND(APPROX_QUANTILES(d, 1000)[OFFSET(25)],  4)             AS ci95_low_bootstrap,
  ROUND(APPROX_QUANTILES(d, 1000)[OFFSET(975)], 4)             AS ci95_high_bootstrap,
  ROUND(COUNTIF(d <= 0) / COUNT(*), 4)                         AS fraction_replicates_non_positive
FROM long
GROUP BY comparison
ORDER BY mean_difference_bootstrap DESC;
