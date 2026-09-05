-- =============================================================================
-- What happened in March 2026, and the concentration measure it produced
-- =============================================================================
-- Produces: data/customer-concentration-monthly.csv
-- Supports: Figure 6, and the 0.093–0.718 range that Sections 3.1, 4.1 and 5.3
--           use to argue that comparing two months compares two mixtures
--
-- An earlier finding recorded March 2026 as anomalous and unexplained: **37,447
-- resolved predictions** against a median near five thousand, a **prevalence of
-- 0.381** against 0.12, accuracy of 0.606 and F1 of 0.015. That month is also
-- the peak of already-closed deals displayed in the top five, at 3.56%.
--
-- The month sits inside every series this work intends to publish. Until it is
-- explained, it either enters with a caveat or leaves with a justification — and
-- both require knowing what it is.
--
-- THREE HYPOTHESES, with distinct signatures:
--
--   (A) BULK RELOAD. Many predictions written at once. Signature: volume
--       concentrated in few days, and requests with far more items than usual.
--   (B) ONE LARGE CUSTOMER. A customer onboarded or was reprocessed. Signature:
--       the concentration is in `tenant_id`, not in date.
--   (C) DATA CORRECTION. The outcome of an old batch was filled in at once.
--       Signature: normal request volume, but a resolution rate far above that
--       of the neighbouring months.
--
-- The three are distinguished by counting, without assuming anything.
-- =============================================================================

-- Statement 1 — the shape of the month against its neighbours: requests,
-- customers, active days and items per request. Separates (A) and (B) from (C).
SELECT
  DATE_TRUNC(DATE(prediction_timestamp), MONTH)                     AS month,
  COUNT(*)                                                          AS rows,
  COUNT(DISTINCT FORMAT('%s|%t', tenant_id, prediction_timestamp))  AS requests,
  COUNT(DISTINCT tenant_id)                                         AS customers,
  COUNT(DISTINCT DATE(prediction_timestamp))                        AS days_with_predictions,
  SAFE_DIVIDE(COUNT(*),
    COUNT(DISTINCT FORMAT('%s|%t', tenant_id, prediction_timestamp))) AS items_per_request,
  SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))                   AS resolution_rate,
  SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL))           AS win_rate
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
WHERE DATE(prediction_timestamp) BETWEEN '2025-12-01' AND '2026-06-30'
GROUP BY month
ORDER BY month;

-- Statement 2 — within March: is the concentration in date or in customer?
-- Ten largest days, with the fraction of the month each one explains.
SELECT
  'day'                                                             AS axis,
  CAST(DATE(prediction_timestamp) AS STRING)                        AS key,
  COUNT(*)                                                          AS rows,
  SAFE_DIVIDE(COUNT(*), SUM(COUNT(*)) OVER ())                      AS fraction_of_month,
  SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))                   AS resolution_rate,
  SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL))           AS win_rate
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
WHERE DATE(prediction_timestamp) BETWEEN '2026-03-01' AND '2026-03-31'
GROUP BY key
ORDER BY rows DESC
LIMIT 10;

-- Statement 3 — the same by customer. `tenant_id` is NOT printed: what comes out
-- is the rank position and the fraction, which are aggregates. This is the
-- anonymisation rule of the project, and it is why this artefact is publishable.
WITH per_customer AS (
  SELECT
    tenant_id,
    COUNT(*)                                                        AS rows,
    SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))                 AS resolution_rate,
    SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL))         AS win_rate
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE DATE(prediction_timestamp) BETWEEN '2026-03-01' AND '2026-03-31'
  GROUP BY tenant_id
),
with_fraction AS (
  SELECT *, SAFE_DIVIDE(rows, SUM(rows) OVER ()) AS fraction_of_month FROM per_customer
)
SELECT
  ROW_NUMBER() OVER (ORDER BY rows DESC)                            AS position,
  rows,
  fraction_of_month,
  SUM(fraction_of_month) OVER (ORDER BY rows DESC
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_fraction,
  resolution_rate,
  win_rate
FROM with_fraction
ORDER BY rows DESC
LIMIT 10;

-- Statement 4 — the 10–13 March cluster, where resolution reaches 0.983. If the
-- age of the deals scored on those days is far above normal, that is the
-- signature of an old batch being reprocessed rather than of current operation.
SELECT
  CASE WHEN DATE(prediction_timestamp) BETWEEN '2026-03-10' AND '2026-03-13'
       THEN 'a 10 to 13 March' ELSE 'b rest of March' END           AS window,
  COUNT(*)                                                          AS rows,
  SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))                   AS resolution_rate,
  SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL))           AS win_rate,
  SAFE_DIVIDE(COUNTIF(deal_status = 'closed'
                      AND closed_at < prediction_timestamp), COUNT(*)) AS already_closed_when_scored,
  APPROX_QUANTILES(DATE_DIFF(DATE(prediction_timestamp), DATE(created_at), DAY), 4)
                                                                    AS quartiles_deal_age
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
WHERE DATE(prediction_timestamp) BETWEEN '2026-03-01' AND '2026-03-31'
GROUP BY window
ORDER BY window;

-- Statement 5 — the generalisation, and it is worth more than March itself.
-- If a single customer can account for 38% of a month, the whole monthly series
-- is vulnerable to a composition effect: a month's metric comes to describe
-- whoever weighed most that month, and not the system. Measuring the
-- concentration EVERY month decides whether March is an isolated incident or the
-- entire series needs a caveat.
WITH per_month_customer AS (
  SELECT
    DATE_TRUNC(DATE(prediction_timestamp), MONTH) AS month,
    tenant_id,
    COUNT(*)                                     AS rows,
    COUNTIF(won IS NOT NULL)                     AS resolved
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  GROUP BY month, tenant_id
),
ordered AS (
  SELECT
    month, rows, resolved,
    SUM(rows) OVER (PARTITION BY month)                       AS rows_in_month,
    SUM(resolved) OVER (PARTITION BY month)                   AS resolved_in_month,
    ROW_NUMBER() OVER (PARTITION BY month ORDER BY rows DESC) AS position
  FROM per_month_customer
)
SELECT
  month,
  COUNT(*)                                                            AS customers,
  MAX(rows_in_month)                                                  AS rows,
  MAX(IF(position = 1, SAFE_DIVIDE(rows, rows_in_month), NULL))       AS fraction_largest_customer,
  SUM(IF(position <= 3, SAFE_DIVIDE(rows, rows_in_month), 0))         AS fraction_three_largest_customers,
  MAX(IF(position = 1, SAFE_DIVIDE(resolved, NULLIF(resolved_in_month, 0)), NULL))
                                                                      AS fraction_resolved_largest_customer
FROM ordered
GROUP BY month
ORDER BY month;
