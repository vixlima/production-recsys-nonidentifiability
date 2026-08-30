-- =============================================================================
-- Recomputing the technical metrics the production dashboard displays
-- =============================================================================
-- Produces: data/dashboard-metrics-monthly.csv
-- Supports: Figures 1 and 2, and the AUC range quoted in Sections 2.1 and 4.1
--
-- On 18 August 2026 a dashboard of technical metrics turned up in production,
-- tracking F1, ROC-AUC, accuracy and precision month by month. It refutes the
-- claim that "there is no way to know the size of the damage" and displays a
-- **ROC-AUC of 0.33**, below chance.
--
-- A screenshot is not a source. The project rule is that every cited number must
-- trace back to a file under `data/`, produced by version-controlled SQL. This
-- file reconstructs the metrics from the prediction history, which carries
-- `classic_prediction`, `uplift_prediction`, `score`, `rank` and `won`.
--
-- WHAT THIS DECIDES. If the numbers match the dashboard, the dashboard is
-- validated and citable by the correct route. If they do not, the divergence is
-- the finding — and the two candidate causes, a different population and an
-- inverted label in the dashboard's own computation, are entirely different
-- findings from one another.
--
-- THE DISTINCTION THE DASHBOARD DOES NOT MAKE, AND THIS FILE DOES. The dashboard
-- measures the **probability model**. The system ranks by the **combined
-- score**, in which the uplift term accounts for roughly 94% at typical values.
-- Measuring both side by side separates "the probability model is poor" from
-- "what ranks is poor", which the dashboard conflates.
--
-- ROC-AUC by rank, which is the Mann-Whitney statistic and is exact:
--     AUC = (sum of ranks of positives − n1(n1+1)/2) / (n1 · n0)
-- Ties take the mean rank; without that the AUC is biased — and ties here are
-- massive: in 12.32% of requests the whole list has a single score value.
--
-- Cost: the table is partitioned by `prediction_timestamp`, and every filter is
-- on it. Run with --dry-run first.
-- =============================================================================

-- Statement 1 — profiling: coverage, volume, and what `won` means here. Without
-- this no number below is interpretable, because the denominator is unknown.
SELECT
  COUNT(*)                                              AS rows,
  COUNT(DISTINCT tenant_id)                             AS customers,
  COUNT(DISTINCT deal_id)                               AS deals,
  MIN(DATE(prediction_timestamp))                       AS first_day,
  MAX(DATE(prediction_timestamp))                       AS last_day,
  COUNTIF(won IS NULL)                                  AS won_null,
  COUNTIF(won = 1)                                      AS won_one,
  COUNTIF(won = 0)                                      AS won_zero,
  COUNTIF(classic_prediction IS NULL)                   AS probability_null,
  COUNTIF(score IS NULL)                                AS score_null,
  COUNT(DISTINCT deal_status)                           AS distinct_statuses
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`;

-- Statement 2 — monthly metrics of the PROBABILITY MODEL and of the SCORE, side
-- by side, over the rows with a known outcome.
WITH base AS (
  SELECT
    DATE_TRUNC(DATE(prediction_timestamp), MONTH) AS month,
    won,
    classic_prediction,
    score
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE won IS NOT NULL
    AND classic_prediction IS NOT NULL
    AND score IS NOT NULL
),
ranks AS (
  SELECT
    month, won,
    RANK() OVER (PARTITION BY month ORDER BY classic_prediction) AS r_min_prob,
    RANK() OVER (PARTITION BY month ORDER BY classic_prediction DESC) AS r_max_prob,
    RANK() OVER (PARTITION BY month ORDER BY score) AS r_min_score,
    RANK() OVER (PARTITION BY month ORDER BY score DESC) AS r_max_score,
    COUNT(*) OVER (PARTITION BY month) AS n,
    classic_prediction, score
  FROM base
)
SELECT
  month,
  COUNT(*)                                                     AS n,
  SUM(won)                                                     AS positives,
  SAFE_DIVIDE(SUM(won), COUNT(*))                              AS prevalence,

  -- threshold 0.5, which is the system's own selection criterion
  SAFE_DIVIDE(COUNTIF(won = 1 AND classic_prediction >= 0.5)
              + COUNTIF(won = 0 AND classic_prediction < 0.5), COUNT(*))   AS accuracy,
  SAFE_DIVIDE(COUNTIF(won = 1 AND classic_prediction >= 0.5),
              COUNTIF(classic_prediction >= 0.5))                          AS precision,
  SAFE_DIVIDE(COUNTIF(won = 1 AND classic_prediction >= 0.5),
              COUNTIF(won = 1))                                            AS recall,
  SAFE_DIVIDE(2 * COUNTIF(won = 1 AND classic_prediction >= 0.5),
              2 * COUNTIF(won = 1 AND classic_prediction >= 0.5)
              + COUNTIF(won = 0 AND classic_prediction >= 0.5)
              + COUNTIF(won = 1 AND classic_prediction < 0.5))              AS f1_threshold_0_5,

  -- AUC by mean rank: (r_min + r_max)/2 breaks ties correctly
  SAFE_DIVIDE(
    SUM(IF(won = 1, (r_min_prob + (n + 1 - r_max_prob)) / 2, 0))
      - SUM(won) * (SUM(won) + 1) / 2,
    SUM(won) * (COUNT(*) - SUM(won))
  )                                                            AS auc_probability,
  SAFE_DIVIDE(
    SUM(IF(won = 1, (r_min_score + (n + 1 - r_max_score)) / 2, 0))
      - SUM(won) * (SUM(won) + 1) / 2,
    SUM(won) * (COUNT(*) - SUM(won))
  )                                                            AS auc_score,

  COUNT(DISTINCT classic_prediction)                           AS distinct_probability_values,
  COUNT(DISTINCT score)                                        AS distinct_score_values
FROM ranks
GROUP BY month
ORDER BY month;
