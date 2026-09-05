-- =============================================================================
-- Who ends up without an outcome: a zombie deal, or a lost outcome?
-- =============================================================================
-- Produces: data/resolution-by-two-ages.csv
-- Supports: the two-ages cross-tabulation of Section 5.2 (formerly Table 5) and the composition argument of Section 5.3
--
-- One open question blocked the paper: **why does the resolution rate FALL with
-- prediction age**, when more elapsed time ought to produce more closure? An
-- earlier finding refuted short enrichment reach — enrichment is coherent per
-- deal and captures closures up to 561 days out.
--
-- The two remaining readings lead to OPPOSITE recommendations:
--
--   (I) BUSINESS REALITY. The CRM accumulates deals that nobody closes and
--       nobody discards. They stay open forever, and there is no outcome to
--       observe. Recommendation: accept the limit and report the interval.
--   (II) INSTRUMENTATION DEFECT. The deal did close, and enrichment failed to
--       record it — because it resolves against a source with limited retention,
--       and 34.45% of scored deals appear in the data warehouse on no day at all.
--       Recommendation: fix the pipeline; the metric is recoverable.
--
-- THIS QUERY DOES NOT DECIDE BETWEEN THEM. It measures the **age signature**,
-- which narrows the space: under (I) a deal without an outcome is old and keeps
-- getting older, with a continuous distribution; under (II) the absence should
-- not depend on the age of the DEAL, only on the age of the PREDICTION. The two
-- ages are different quantities and the table carries both.
--
-- The decisive test is a join against the change data capture stream, costs tens
-- of gigabytes, and whether to spend it depends on what comes out of here.
-- =============================================================================

-- Statement 1 — the two ages, by outcome status.
-- `deal_age` runs from `created_at` to the prediction; `prediction_age` runs
-- from the prediction to today. Under (I) the first separates; under (II) the
-- second does.
SELECT
  CASE WHEN won IS NULL THEN 'a without outcome' ELSE 'b with outcome' END AS status,
  COUNT(*)                                                          AS rows,
  COUNT(DISTINCT deal_id)                                           AS deals,
  APPROX_QUANTILES(DATE_DIFF(DATE(prediction_timestamp), DATE(created_at), DAY), 10)
                                                                    AS deciles_deal_age,
  APPROX_QUANTILES(DATE_DIFF(CURRENT_DATE(), DATE(prediction_timestamp), DAY), 10)
                                                                    AS deciles_prediction_age,
  -- how long a deal WITHOUT an outcome has been open, counted to today
  APPROX_QUANTILES(DATE_DIFF(CURRENT_DATE(), DATE(created_at), DAY), 10)
                                                                    AS deciles_time_since_creation
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
GROUP BY status
ORDER BY status;

-- Statement 2 — the resolution rate crossing the TWO ages.
-- If it falls with prediction age **within** each band of deal age, then deal
-- age does not explain it and (II) gains force. If the fall disappears once
-- controlled, it was confounding and (I) gains force.
SELECT
  CASE
    WHEN DATE_DIFF(DATE(prediction_timestamp), DATE(created_at), DAY) <= 30  THEN 'i   up to 30d'
    WHEN DATE_DIFF(DATE(prediction_timestamp), DATE(created_at), DAY) <= 90  THEN 'ii  31 to 90d'
    WHEN DATE_DIFF(DATE(prediction_timestamp), DATE(created_at), DAY) <= 365 THEN 'iii 91 to 365d'
    ELSE                                                                          'iv  365d+'
  END                                                               AS deal_age,
  CASE
    WHEN DATE_DIFF(CURRENT_DATE(), DATE(prediction_timestamp), DAY) >= 365 THEN '3 prediction 365d+'
    WHEN DATE_DIFF(CURRENT_DATE(), DATE(prediction_timestamp), DAY) >= 180 THEN '2 prediction 180-364'
    ELSE                                                                        '1 prediction up to 179'
  END                                                               AS prediction_age,
  COUNT(*)                                                          AS rows,
  SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))                   AS resolution_rate
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
GROUP BY deal_age, prediction_age
ORDER BY deal_age, prediction_age;
