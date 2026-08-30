-- =============================================================================
-- Do already-closed deals actually get DISPLAYED to the salesperson?
-- =============================================================================
-- Produces: data/closed-deals-shown-at-top-monthly.csv
-- Supports: the displaced-position figures quoted in Section 2
--
-- An earlier finding established that 5.23% of closed rows are scored after the
-- deal had already closed, through a leak in the candidate-list filter. It also
-- declared what was missing to turn that from a pipeline defect into a product
-- impact: **how many of those land in the top five**, which is what the
-- interface shows.
--
-- The question matters because a closed deal occupying one of the five positions
-- DISPLACES an open one. The cost is not the inference spend, it is the position.
--
-- THE DENOMINATOR, and it needs care. The 5.23% figure is over CLOSED rows,
-- because only those have `closed_at`. To measure display, the correct
-- denominator is **all top-five rows**, open and closed alike — that is what the
-- salesperson saw. Comparing the two numbers without that distinction would
-- produce the wrong conclusion.
-- =============================================================================

-- Statement 1 — the share of the top five that was already closed when displayed.
SELECT
  CASE WHEN rank <= 5 THEN 'a top-5 (displayed)' ELSE 'b outside top-5' END    AS band,
  COUNT(*)                                                                     AS rows,
  COUNTIF(deal_status = 'closed' AND closed_at < prediction_timestamp)         AS already_closed,
  SAFE_DIVIDE(COUNTIF(deal_status = 'closed' AND closed_at < prediction_timestamp),
              COUNT(*))                                                        AS fraction_of_displayed
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
GROUP BY band
ORDER BY band;

-- Statement 2 — the same thing by month, restricted to the top five. This is the
-- series that says whether the salesperson sees more junk today than in 2025.
SELECT
  DATE_TRUNC(DATE(prediction_timestamp), MONTH)                                AS month,
  COUNT(*)                                                                     AS rows_top5,
  COUNTIF(deal_status = 'closed' AND closed_at < prediction_timestamp)         AS already_closed_in_top5,
  SAFE_DIVIDE(COUNTIF(deal_status = 'closed' AND closed_at < prediction_timestamp),
              COUNT(*))                                                        AS fraction
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
WHERE rank <= 5
GROUP BY month
ORDER BY month;

-- Statement 3 — how many REQUESTS had at least one closed deal in the top five.
-- The unit here is the list the salesperson opened, which is the product's unit.
WITH per_request AS (
  SELECT
    tenant_id, prediction_timestamp,
    COUNTIF(rank <= 5)                                                         AS items_top5,
    COUNTIF(rank <= 5 AND deal_status = 'closed'
            AND closed_at < prediction_timestamp)                              AS closed_in_top5
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  GROUP BY tenant_id, prediction_timestamp
)
SELECT
  COUNT(*)                                                                     AS requests,
  COUNTIF(items_top5 >= 5)                                                     AS requests_with_full_top5,
  COUNTIF(closed_in_top5 > 0)                                                  AS requests_with_a_closed_deal,
  SAFE_DIVIDE(COUNTIF(closed_in_top5 > 0), COUNT(*))                           AS fraction_of_requests,
  SUM(closed_in_top5)                                                          AS wasted_positions
FROM per_request;
