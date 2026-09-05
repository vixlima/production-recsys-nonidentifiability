-- =============================================================================
-- The top-5 against the rest OF THE SAME LIST, paired by request
-- =============================================================================
-- Produces: data/top5-vs-rest-within-request.csv
-- Supports: the within-request contrast of Section 5.1 (+6.48 pp mean, median
-- 0.00, top-5 better in 36.3% of requests) and the second row of Table 6.
--
-- Why it exists. An earlier draft of the paper used, as evidence of "signal at
-- the top", the win-rate gradient by rank band — which is POOLED across requests
-- of different sizes, and therefore subject to the paper's own third mechanism,
-- composition. The clean contrast, within the request, is this one: the same
-- list, split at the fifth position, with customer and instant constant by
-- construction.
--
-- UNIT: the request. Only requests with at least one resolved deal in the first
-- five positions AND at least one resolved deal beyond them enter, without which
-- the contrast is undefined. The rate in each part is computed among resolved
-- deals — it is theta three, the quantity the log allows, not theta two.
-- Reports the mean, the standard error, the median and the fraction of requests
-- in which the top-5 is better, equal or worse, which is the distribution the
-- paper's Section 2.4 asks for rather than the point estimate alone.
-- Cost: the same small table as queries 04 to 15. Dry-run first.
-- =============================================================================
WITH resolved AS (
  SELECT tenant_id, prediction_timestamp, rank, won
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE won IS NOT NULL
),
per_request AS (
  SELECT
    tenant_id, prediction_timestamp,
    COUNTIF(rank <= 5)                                          AS resolved_top5,
    COUNTIF(rank > 5)                                           AS resolved_rest,
    SAFE_DIVIDE(COUNTIF(rank <= 5 AND won = 1), COUNTIF(rank <= 5)) AS rate_top5,
    SAFE_DIVIDE(COUNTIF(rank > 5 AND won = 1),  COUNTIF(rank > 5))  AS rate_rest
  FROM resolved
  GROUP BY tenant_id, prediction_timestamp
  HAVING resolved_top5 >= 1 AND resolved_rest >= 1
),
diff AS (
  SELECT *, rate_top5 - rate_rest AS d FROM per_request
)
SELECT
  COUNT(*)                                                     AS requests,
  AVG(rate_top5)                                               AS mean_win_rate_top5,
  AVG(rate_rest)                                               AS mean_win_rate_rest,
  AVG(d)                                                       AS mean_difference,
  STDDEV(d) / SQRT(COUNT(*))                                   AS standard_error,
  SAFE_DIVIDE(AVG(d), STDDEV(d) / SQRT(COUNT(*)))              AS t,
  APPROX_QUANTILES(d, 1000)[OFFSET(500)]                       AS median_difference,
  APPROX_QUANTILES(d, 1000)[OFFSET(250)]                       AS difference_q1,
  APPROX_QUANTILES(d, 1000)[OFFSET(750)]                       AS difference_q3,
  SAFE_DIVIDE(COUNTIF(d > 0), COUNT(*))                        AS fraction_top5_better,
  SAFE_DIVIDE(COUNTIF(d = 0), COUNT(*))                        AS fraction_tie,
  SAFE_DIVIDE(COUNTIF(d < 0), COUNT(*))                        AS fraction_top5_worse,
  COUNT(DISTINCT tenant_id)                                    AS customers
FROM diff;
