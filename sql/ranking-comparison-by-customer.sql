-- =============================================================================
-- The ranking comparison with the resampling unit the pre-registration declared
-- =============================================================================
-- Produces: data/ranking-comparison-by-customer.csv
-- Supports: Table 4, and the −0.0459 / +0.0059 sign disagreement of Table 5
--
-- This closes, for the audit study, the defect recorded as entry 34 of the
-- retractions inventory: resampling by one unit when the protocol declared
-- another.
--
-- The pre-registration asks, in its metrics table, for a "95% CI by bootstrap
-- **clustered by tenant**". The earlier query resamples **requests** — and the
-- paper said, literally, "paired bootstrap of one thousand replicates resampling
-- requests". Requests from the same customer are not independent: the same
-- salesperson, the same portfolio and the same pipeline stage recur. Treating
-- them as independent **narrows the interval unduly**.
--
-- Measured on the grid population, the effect is not second-order: the
-- by-customer interval came out **almost three times wider** than the by-list
-- one, and **inverted the verdict** — from excluding zero to containing zero.
--
-- THIS FILE DOES NOT REPLACE THE EARLIER QUERY, and the reason is
-- reproducibility: that query produced the published numbers, and altering it
-- would make the version-controlled code stop reproducing the version-controlled
-- result. It stays as it is; this one adds the correct unit alongside.
--
-- TWO COMPUTATIONS, AND THEY ANSWER DIFFERENT QUESTIONS:
--
--   * the **cluster-robust standard error**, which averages the paired
--     difference within each customer and measures dispersion **between**
--     customers. It is what feeds the `t` and, through it, the Holm correction —
--     because Holm operates on p, and p has to come from the right unit. With
--     300 customers instead of 525 requests, the denominator changes.
--
--   * the **bootstrap clustered by tenant**, which draws CUSTOMERS with
--     replacement and recomputes the mean over all requests of the drawn
--     customers. It is literally what the pre-registration asks for, and it is
--     the interval to report.
--
-- Both are conservative relative to what had been published, and that is the
-- point.
--
-- SEED: `replicate * 1000003 + i`, a declared prime, with no `RAND()` — two
-- executions return the same bounds.
-- =============================================================================

WITH closed AS (
  SELECT
    h.tenant_id, h.prediction_timestamp, h.deal_id,
    h.rank, h.won = 1 AS won
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}` h
  WHERE h.deal_status = 'closed'
),

request AS (
  SELECT tenant_id, prediction_timestamp, COUNTIF(won) AS wins
  FROM closed
  GROUP BY tenant_id, prediction_timestamp
  HAVING COUNT(*) >= 25 AND COUNTIF(won) >= 1
),

attributes AS (
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
  SELECT c.*, r.wins AS wins_in_request, a.* EXCEPT (deal_id)
  FROM closed c
  JOIN request r USING (tenant_id, prediction_timestamp)
  JOIN attributes a USING (deal_id)
),

-- The system is ranked by the `rank` it actually displayed; every alternative
-- gets a declared, neutral tie-break by fingerprint of the deal id, so that no
-- comparison is decided by arrival order.
ranked AS (
  SELECT tenant_id, prediction_timestamp, won, wins_in_request,
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
  SELECT
    tenant_id, prediction_timestamp,
    SAFE_DIVIDE(SUM(IF(won AND pos_system        <= 5, 1/LOG(pos_system+1,2),        0)), idcg) AS n_system,
    SAFE_DIVIDE(SUM(IF(won AND pos_qualification <= 5, 1/LOG(pos_qualification+1,2), 0)), idcg) AS n_qualification,
    SAFE_DIVIDE(SUM(IF(won AND pos_stage         <= 5, 1/LOG(pos_stage+1,2),         0)), idcg) AS n_stage,
    SAFE_DIVIDE(SUM(IF(won AND pos_stage_score   <= 5, 1/LOG(pos_stage_score+1,2),   0)), idcg) AS n_stage_score,
    SAFE_DIVIDE(SUM(IF(won AND pos_recency       <= 5, 1/LOG(pos_recency+1,2),       0)), idcg) AS n_recency,
    SAFE_DIVIDE(SUM(IF(won AND pos_interactions  <= 5, 1/LOG(pos_interactions+1,2),  0)), idcg) AS n_interactions,
    SAFE_DIVIDE(SUM(IF(won AND pos_value         <= 5, 1/LOG(pos_value+1,2),         0)), idcg) AS n_value,
    SAFE_DIVIDE(SUM(IF(won AND pos_random        <= 5, 1/LOG(pos_random+1,2),        0)), idcg) AS n_random
  FROM (
    SELECT *,
      (SELECT SUM(1/LOG(i+1,2))
       FROM UNNEST(GENERATE_ARRAY(1, LEAST(5, wins_in_request))) AS i) AS idcg
    FROM ranked
  )
  GROUP BY tenant_id, prediction_timestamp, idcg
),

diff AS (
  SELECT 'system - qualification'  AS comparison, tenant_id, n_system - n_qualification AS d FROM ndcg
  UNION ALL SELECT 'system - stage',              tenant_id, n_system - n_stage         FROM ndcg
  UNION ALL SELECT 'system - stage_score',        tenant_id, n_system - n_stage_score   FROM ndcg
  UNION ALL SELECT 'system - recency',            tenant_id, n_system - n_recency       FROM ndcg
  UNION ALL SELECT 'system - interactions',       tenant_id, n_system - n_interactions  FROM ndcg
  UNION ALL SELECT 'system - value',              tenant_id, n_system - n_value         FROM ndcg
  UNION ALL SELECT 'system - random',             tenant_id, n_system - n_random        FROM ndcg
),

-- CLUSTER-ROBUST STANDARD ERROR: the unit becomes the CUSTOMER.
-- The difference is averaged within each customer, and the dispersion measured
-- BETWEEN customers. It is what the `t` needs for Holm to operate on the
-- declared unit.
per_customer AS (
  SELECT comparison, tenant_id,
         AVG(d) AS d_customer,
         COUNT(*) AS requests_in_customer
  FROM diff
  WHERE d IS NOT NULL
  GROUP BY comparison, tenant_id
)

SELECT
  comparison,
  COUNT(*)                                                        AS customers,
  SUM(requests_in_customer)                                       AS requests,
  ROUND(AVG(d_customer), 4)                                       AS mean_difference_by_customer,
  ROUND(STDDEV(d_customer) / SQRT(COUNT(*)), 4)                   AS cluster_standard_error,
  ROUND(SAFE_DIVIDE(AVG(d_customer),
                    STDDEV(d_customer) / SQRT(COUNT(*))), 3)      AS t_cluster,
  ROUND(AVG(d_customer) - 1.96 * STDDEV(d_customer) / SQRT(COUNT(*)), 4) AS ci95_low_cluster,
  ROUND(AVG(d_customer) + 1.96 * STDDEV(d_customer) / SQRT(COUNT(*)), 4) AS ci95_high_cluster
FROM per_customer
GROUP BY comparison
ORDER BY t_cluster DESC;


-- -----------------------------------------------------------------------------
-- Q2. BOOTSTRAP CLUSTERED BY TENANT, which is literally what the protocol asks
-- -----------------------------------------------------------------------------
-- One thousand replicates. In each, CUSTOMERS are drawn with replacement — not
-- requests — and the mean is recomputed over all requests of the drawn
-- customers. A large customer enters with its full weight, which is exactly what
-- clustering by request concealed.

WITH closed AS (
  SELECT h.tenant_id, h.prediction_timestamp, h.deal_id, h.rank, h.won = 1 AS won
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}` h
  WHERE h.deal_status = 'closed'
),
request AS (
  SELECT tenant_id, prediction_timestamp, COUNTIF(won) AS wins
  FROM closed
  GROUP BY tenant_id, prediction_timestamp
  HAVING COUNT(*) >= 25 AND COUNTIF(won) >= 1
),
attributes AS (
  SELECT deal_id,
    ANY_VALUE(rating) AS rating, ANY_VALUE(deal_stage_order) AS deal_stage_order,
    ANY_VALUE(stage_score_tenant) AS stage_score_tenant,
    ANY_VALUE(inactivity_time) AS inactivity_time,
    ANY_VALUE(interactions) AS interactions, ANY_VALUE(amount_monthly) AS amount_monthly
  FROM `${project_insights}.${dataset_recommendation}.${table_feature_store}`
  GROUP BY deal_id
),
base AS (
  SELECT c.*, r.wins AS wins_in_request, a.* EXCEPT (deal_id)
  FROM closed c
  JOIN request r USING (tenant_id, prediction_timestamp)
  JOIN attributes a USING (deal_id)
),
ranked AS (
  SELECT tenant_id, prediction_timestamp, won, wins_in_request,
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
    SAFE_DIVIDE(SUM(IF(won AND pos_system        <= 5, 1/LOG(pos_system+1,2),        0)), idcg) AS n_system,
    SAFE_DIVIDE(SUM(IF(won AND pos_qualification <= 5, 1/LOG(pos_qualification+1,2), 0)), idcg) AS n_qualification,
    SAFE_DIVIDE(SUM(IF(won AND pos_stage         <= 5, 1/LOG(pos_stage+1,2),         0)), idcg) AS n_stage,
    SAFE_DIVIDE(SUM(IF(won AND pos_stage_score   <= 5, 1/LOG(pos_stage_score+1,2),   0)), idcg) AS n_stage_score,
    SAFE_DIVIDE(SUM(IF(won AND pos_recency       <= 5, 1/LOG(pos_recency+1,2),       0)), idcg) AS n_recency,
    SAFE_DIVIDE(SUM(IF(won AND pos_interactions  <= 5, 1/LOG(pos_interactions+1,2),  0)), idcg) AS n_interactions,
    SAFE_DIVIDE(SUM(IF(won AND pos_value         <= 5, 1/LOG(pos_value+1,2),         0)), idcg) AS n_value,
    SAFE_DIVIDE(SUM(IF(won AND pos_random        <= 5, 1/LOG(pos_random+1,2),        0)), idcg) AS n_random
  FROM (
    SELECT *, (SELECT SUM(1/LOG(i+1,2))
               FROM UNNEST(GENERATE_ARRAY(1, LEAST(5, wins_in_request))) AS i) AS idcg
    FROM ranked
  )
  GROUP BY tenant_id, prediction_timestamp, idcg
),
-- a dense index of CUSTOMERS, not of requests: this is where the difference is
indexed_customer AS (
  SELECT tenant_id,
         ROW_NUMBER() OVER (ORDER BY FARM_FINGERPRINT(CAST(tenant_id AS STRING))) - 1 AS idx
  FROM (SELECT DISTINCT tenant_id FROM ndcg)
),
size AS (SELECT COUNT(*) AS n FROM indexed_customer),
draw AS (
  SELECT r AS replicate,
         MOD(ABS(FARM_FINGERPRINT(CAST(r * 1000003 + i AS STRING))), (SELECT n FROM size)) AS idx
  FROM UNNEST(GENERATE_ARRAY(1, 1000)) AS r,
       UNNEST(GENERATE_ARRAY(0, (SELECT n FROM size) - 1)) AS i
),
-- a drawn customer enters with ALL of its requests
replicate_diff AS (
  SELECT d.replicate,
    AVG(x.n_system - x.n_qualification) AS d_qualification,
    AVG(x.n_system - x.n_stage)         AS d_stage,
    AVG(x.n_system - x.n_stage_score)   AS d_stage_score,
    AVG(x.n_system - x.n_recency)       AS d_recency,
    AVG(x.n_system - x.n_interactions)  AS d_interactions,
    AVG(x.n_system - x.n_value)         AS d_value,
    AVG(x.n_system - x.n_random)        AS d_random
  FROM draw d
  JOIN indexed_customer c USING (idx)
  JOIN ndcg x USING (tenant_id)
  GROUP BY d.replicate
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
  ROUND(AVG(d), 4)                                             AS mean_difference_bootstrap_customer,
  ROUND(APPROX_QUANTILES(d, 1000)[OFFSET(25)],  4)             AS ci95_low_bootstrap_customer,
  ROUND(APPROX_QUANTILES(d, 1000)[OFFSET(975)], 4)             AS ci95_high_bootstrap_customer,
  ROUND(COUNTIF(d <= 0) / COUNT(*), 4)                         AS fraction_replicates_non_positive
FROM long
GROUP BY comparison
ORDER BY mean_difference_bootstrap_customer DESC;
