-- =============================================================================
-- The monthly series with customer composition controlled for
-- =============================================================================
-- Produces: data/win-rate-series-two-aggregations.csv
-- Supports: Figure 7 and the −0.019 / +0.060 pair in Sections 5.3 and 6.2
--
-- An earlier finding showed that the monthly series measures customer
-- composition: the largest customer accounts for 9.3% to 71.8% of the month's
-- rows, and for 0.2% to 70.4% of the resolved ones. The consequence was harsh —
-- the reading that performance declines over time was **discarded by
-- non-identifiability**, not by having been tested.
--
-- That finding declared the next step: control for composition. This is it.
--
-- TWO WAYS TO CONTROL, and they err in different directions:
--
--   (1) MEAN OF MEANS. Compute the rate per (month, customer) and average across
--       customers WITHOUT weighting. Removes the weight of size. Cost: it now
--       measures the typical customer rather than the operation, and a small
--       customer counts as much as a large one.
--   (2) BALANCED PANEL. Restrict to customers present in many months and measure
--       only within them. **Fixes the mixture by construction**, which is the
--       stronger control. Cost: discards most customers and comes to describe
--       the long-standing ones.
--
-- Both change the estimand, and that is declared rather than hidden: neither is
-- "the corrected series". They are three different series answering three
-- different questions, and the comparison between them is the result.
--
-- MINIMUM PER CELL: 30 resolved rows per (month, customer). Without it the
-- per-customer rate is noise, and the mean of means amplifies noise instead of
-- removing weight.
-- =============================================================================

WITH per_month_customer AS (
  SELECT
    DATE_TRUNC(DATE(prediction_timestamp), MONTH)                   AS month,
    tenant_id,
    COUNT(*)                                                        AS rows,
    COUNTIF(won IS NOT NULL)                                        AS resolved,
    COUNTIF(won = 1)                                                AS wins
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  GROUP BY month, tenant_id
),
eligible AS (
  SELECT *, SAFE_DIVIDE(wins, resolved) AS win_rate
  FROM per_month_customer
  WHERE resolved >= 30
),
-- customers present in at least twelve of the twenty eligible months
veterans AS (
  SELECT tenant_id
  FROM eligible
  GROUP BY tenant_id
  HAVING COUNT(DISTINCT month) >= 12
)
SELECT
  e.month,
  -- (0) raw: weighted by size, which is what the dashboard does
  SAFE_DIVIDE(SUM(e.wins), SUM(e.resolved))                         AS weighted_raw,
  -- (1) mean of means across eligible customers
  AVG(e.win_rate)                                                   AS mean_of_means,
  COUNT(*)                                                          AS eligible_customers,
  -- (2) balanced panel: veterans only, weighted within them
  SAFE_DIVIDE(SUM(IF(v.tenant_id IS NOT NULL, e.wins, 0)),
              SUM(IF(v.tenant_id IS NOT NULL, e.resolved, 0)))       AS balanced_panel,
  COUNTIF(v.tenant_id IS NOT NULL)                                  AS veterans_in_month,
  -- concentration, to be read alongside
  SAFE_DIVIDE(MAX(e.rows), SUM(e.rows))                             AS fraction_largest_customer
FROM eligible AS e
LEFT JOIN veterans AS v USING (tenant_id)
GROUP BY e.month
ORDER BY e.month;
