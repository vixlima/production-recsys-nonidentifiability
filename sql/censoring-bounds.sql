-- =============================================================================
-- Bounds on precision@5 under censoring, instead of "direction not determined"
-- =============================================================================
-- Produces: data/censoring-bounds.csv
-- Supports: Figure 4, and the 0.0849–0.7508 interval that Sections 4.2 and 5.2
--           report as the paper's central identification result
--
-- An earlier finding established that the censoring is **informative**: the
-- resolution rate ranges from 0.19 to 0.40 across score bands, and independence
-- between censoring and score is refuted. That finding declared that the
-- **direction of the bias was not signed**, which is honest and is very little.
--
-- One can do better without assuming anything: instead of estimating the bias,
-- **bound the metric**. The 69.36% of predictions without an outcome can only
-- take two values, so the true precision@5 necessarily lies between two
-- computable numbers. Bounds in the spirit of Manski: they do not identify a
-- point, they identify an interval, and **the width of the interval is the
-- result** — it measures how much the censored data simply does not answer.
--
-- FOUR QUANTITIES, and the difference between them is the subject:
--
--   observed    — resolved positions only, which is what the dashboard and every
--                 earlier computation does. It holds under the assumption that
--                 the missingness is ignorable, which is REFUTED.
--   lower bound — every prediction without an outcome treated as a LOSS.
--   upper bound — every prediction without an outcome treated as a WIN.
--   under MAR   — each missing position takes the win rate observed AT THE SAME
--                 RANK POSITION. This is not assumption-free: it assumes
--                 missingness ignorable *given the rank*, which is weaker than
--                 ignorable in general, and it is declared as an assumption
--                 rather than as a measurement.
--
-- UNIT: the request, and only those with five or more items — below that
-- precision@5 is undefined, and including them mixes two things.
--
-- POSITION, not band: the win rate is estimated at each exact position from 1 to
-- 5, so that the MAR estimator has real variation instead of collapsing onto the
-- mean of the top.
-- =============================================================================

-- Statement 1 — the observed win rate at each position of the top five.
-- It is the input to the MAR estimator, and is interesting in itself: it says
-- whether the ranking discriminates WITHIN the five displayed, and not only
-- between top and tail.
SELECT
  rank                                                              AS position,
  COUNT(*)                                                          AS rows,
  COUNTIF(won IS NOT NULL)                                          AS resolved,
  SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))                   AS resolution_rate,
  SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL))           AS observed_win_rate
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
WHERE rank <= 5
GROUP BY position
ORDER BY position;

-- Statement 2 — the bounds, over requests with five or more items.
WITH rate_by_position AS (
  SELECT rank, SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL)) AS p_win
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE rank <= 5
  GROUP BY rank
),
top AS (
  SELECT
    h.tenant_id, h.prediction_timestamp, h.rank, h.won, r.p_win,
    COUNT(*) OVER (PARTITION BY h.tenant_id, h.prediction_timestamp) AS items_top5
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}` AS h
  JOIN rate_by_position AS r USING (rank)
  WHERE h.rank <= 5
),
per_request AS (
  SELECT
    tenant_id, prediction_timestamp,
    COUNT(*)                                                        AS items,
    COUNTIF(won IS NOT NULL)                                        AS resolved,
    -- observed: only resolved positions enter BOTH numerator and denominator
    SAFE_DIVIDE(COUNTIF(won = 1), NULLIF(COUNTIF(won IS NOT NULL), 0))  AS p5_observed,
    -- bounds: the denominator is always what was displayed, five
    SAFE_DIVIDE(COUNTIF(won = 1), COUNT(*))                         AS p5_lower_bound,
    SAFE_DIVIDE(COUNTIF(won = 1) + COUNTIF(won IS NULL), COUNT(*))  AS p5_upper_bound,
    -- MAR: each missing position takes the rate of its own rank
    SAFE_DIVIDE(COUNTIF(won = 1) + SUM(IF(won IS NULL, p_win, 0)), COUNT(*)) AS p5_mar
  FROM top
  WHERE items_top5 >= 5
  GROUP BY tenant_id, prediction_timestamp
)
SELECT
  COUNT(*)                                                          AS requests,
  AVG(resolved)                                                     AS mean_resolved_items,
  SAFE_DIVIDE(SUM(resolved), SUM(items))                            AS fraction_resolved,
  AVG(p5_observed)                                                  AS p5_observed,
  AVG(p5_lower_bound)                                               AS p5_lower_bound,
  AVG(p5_upper_bound)                                               AS p5_upper_bound,
  AVG(p5_mar)                                                       AS p5_mar,
  AVG(p5_upper_bound) - AVG(p5_lower_bound)                         AS interval_width,
  COUNTIF(resolved = 0)                                             AS requests_with_none_resolved
FROM per_request;

-- Statement 3 — the same bounds by year, because censoring depends on elapsed
-- time and 2025 has far more of it than 2026. If the interval were narrow in
-- 2025 and wide in 2026, the reading would change: the problem would be one of
-- recency rather than of design.
WITH rate_by_position AS (
  SELECT rank, SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL)) AS p_win
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE rank <= 5
  GROUP BY rank
),
top AS (
  SELECT
    h.tenant_id, h.prediction_timestamp, h.won, r.p_win,
    EXTRACT(YEAR FROM h.prediction_timestamp)                       AS year,
    COUNT(*) OVER (PARTITION BY h.tenant_id, h.prediction_timestamp) AS items_top5
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}` AS h
  JOIN rate_by_position AS r USING (rank)
  WHERE h.rank <= 5
),
per_request AS (
  SELECT
    year, tenant_id, prediction_timestamp,
    SAFE_DIVIDE(COUNTIF(won = 1), NULLIF(COUNTIF(won IS NOT NULL), 0))  AS p5_observed,
    SAFE_DIVIDE(COUNTIF(won = 1), COUNT(*))                         AS p5_lower_bound,
    SAFE_DIVIDE(COUNTIF(won = 1) + COUNTIF(won IS NULL), COUNT(*))  AS p5_upper_bound,
    SAFE_DIVIDE(COUNTIF(won = 1) + SUM(IF(won IS NULL, p_win, 0)), COUNT(*)) AS p5_mar,
    SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))                 AS fraction_resolved
  FROM top
  WHERE items_top5 >= 5
  GROUP BY year, tenant_id, prediction_timestamp
)
SELECT
  year,
  COUNT(*)                                                          AS requests,
  AVG(fraction_resolved)                                            AS fraction_resolved,
  AVG(p5_observed)                                                  AS p5_observed,
  AVG(p5_lower_bound)                                               AS p5_lower_bound,
  AVG(p5_upper_bound)                                               AS p5_upper_bound,
  AVG(p5_mar)                                                       AS p5_mar,
  AVG(p5_upper_bound) - AVG(p5_lower_bound)                         AS interval_width
FROM per_request
GROUP BY year
ORDER BY year;
