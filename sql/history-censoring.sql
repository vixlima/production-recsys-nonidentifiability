-- =============================================================================
-- Censoring of the prediction history: administrative or informative?
-- =============================================================================
-- Produces: data/censoring-by-score.csv and data/censoring-by-rank-and-age.csv
-- Supports: Figure 3, and the 0.2347 → 0.3989 → 0.2433 resolution profile that
--           Section 5.2 uses to refute independence between censoring and score
--
-- 69.36% of predictions have no known outcome, and every metric computed
-- elsewhere in this work lives in the remaining 30.64%. Quantifying that has
-- been done. What is missing is what decides whether those numbers describe
-- anything at all: **is the censoring informative?**
--
-- THE DISTINCTION THAT MATTERS:
--
--   ADMINISTRATIVE censoring — the deal has not closed because the prediction is
--   recent and there has not been time. It is benign for the reading: it biases
--   volume, not the comparison between positions in the list.
--
--   INFORMATIVE censoring — the probability of closing depends on where the deal
--   landed in the list, or on the score it received. Then precision@5 is
--   measuring, in part, who got an observed outcome rather than who was ranked
--   well. The bias has a direction and the reading changes.
--
-- HOW TO SEPARATE THEM. Administrative censoring is removed by conditioning on
-- the AGE of the prediction: among predictions old enough for any deal to have
-- closed, whatever dependence remains between resolution and position is
-- informative. If the resolution rate is flat in `rank` within the old stratum,
-- the censoring is administrative and the published numbers stand. If it rises
-- or falls with `rank`, they do not stand as they are.
--
-- THIS QUERY CORRECTS NOTHING. It measures the direction and the size of the
-- problem. The correction, if needed, is a design decision and belongs in the
-- protocol.
-- =============================================================================

-- Statement 1 — what `deal_status` means, and whether a null `won` is equivalent
-- to an open deal. Without this, "censoring" is a name I gave rather than a
-- mechanism I know.
SELECT
  deal_status,
  COUNT(*)                                                    AS rows,
  COUNTIF(won IS NULL)                                        AS won_null,
  COUNTIF(won = 1)                                            AS won_one,
  COUNTIF(won = 0)                                            AS won_zero,
  COUNTIF(closed_at IS NULL)                                  AS without_closing_date,
  COUNTIF(closed_at IS NOT NULL AND won IS NULL)              AS closed_but_no_outcome,
  MIN(DATE(prediction_timestamp))                             AS first_prediction,
  MAX(DATE(prediction_timestamp))                             AS last_prediction
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
GROUP BY deal_status
ORDER BY rows DESC;

-- Statement 2 — the central question: does the resolution rate depend on
-- POSITION? Crossed with prediction age, which is what separates administrative
-- from informative. The stratum of 365 days or more is the one that decides.
SELECT
  CASE
    WHEN rank <= 5   THEN 'a 1-5 (displayed)'
    WHEN rank <= 10  THEN 'b 6-10'
    WHEN rank <= 20  THEN 'c 11-20'
    WHEN rank <= 50  THEN 'd 21-50'
    ELSE                  'e 51+'
  END                                                         AS rank_band,
  CASE
    WHEN DATE_DIFF(CURRENT_DATE(), DATE(prediction_timestamp), DAY) >= 365 THEN 'iii 365+ days'
    WHEN DATE_DIFF(CURRENT_DATE(), DATE(prediction_timestamp), DAY) >= 180 THEN 'ii 180-364'
    ELSE                                                                        'i up to 179'
  END                                                         AS prediction_age,
  COUNT(*)                                                    AS rows,
  SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))             AS resolution_rate,
  SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL))     AS win_rate_among_resolved,
  AVG(score)                                                  AS score_mean
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
GROUP BY rank_band, prediction_age
ORDER BY prediction_age, rank_band;

-- Statement 3 — the same question from the SCORE side.
-- If resolution rises with the score, the model is being evaluated
-- preferentially where it itself pointed, which is the most perverse form of
-- informative censoring. Restricted to the old stratum, where elapsed time no
-- longer explains anything.
--
-- DEFECT FIXED ON 19 AUGUST 2026, and it is of a kind this project has already
-- paid for three times. The first version cut by `NTILE(10) OVER (ORDER BY
-- score)`. NTILE **is not deterministic under ties**: rows with the same score
-- land in different deciles on each execution, and the score ties massively —
-- 12.32% of requests carry a single value across the whole list. Two executions
-- over the same table returned seven of the ten deciles different. Caught by the
-- rule of running everything twice; without it, it would have become a published
-- number.
--
-- The fix has two parts. The score band the system itself records, `score_band`,
-- becomes the primary cut: it is deterministic, has no ties to resolve, and is
-- the bucketing the product uses. The decile stays as secondary, with a
-- **declared, neutral tie-break** — `deal_id` and the prediction instant, which
-- derive from neither the score nor the outcome.
SELECT
  'band'                                                      AS cutoff,
  score_band                                                  AS bucket,
  COUNT(*)                                                    AS rows,
  MIN(score)                                                  AS score_min,
  MAX(score)                                                  AS score_max,
  SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))             AS resolution_rate,
  SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL))     AS win_rate_among_resolved
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
WHERE DATE_DIFF(CURRENT_DATE(), DATE(prediction_timestamp), DAY) >= 365
GROUP BY score_band
ORDER BY score_min;

-- Statement 4 — the decile, now deterministic.
WITH deciles AS (
  SELECT
    score, won,
    NTILE(10) OVER (ORDER BY score, deal_id, prediction_timestamp) AS decile
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE DATE_DIFF(CURRENT_DATE(), DATE(prediction_timestamp), DAY) >= 365
)
SELECT
  'decile'                                                    AS cutoff,
  CAST(decile AS STRING)                                      AS bucket,
  COUNT(*)                                                    AS rows,
  MIN(score)                                                  AS score_min,
  MAX(score)                                                  AS score_max,
  SAFE_DIVIDE(COUNTIF(won IS NOT NULL), COUNT(*))             AS resolution_rate,
  SAFE_DIVIDE(COUNTIF(won = 1), COUNTIF(won IS NOT NULL))     AS win_rate_among_resolved
FROM deciles
GROUP BY decile
ORDER BY decile;
