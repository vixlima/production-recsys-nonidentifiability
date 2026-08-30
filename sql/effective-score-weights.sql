-- =============================================================================
-- The effective weights of the composite score, over the whole population
-- =============================================================================
-- Produces: data/effective-score-weights.csv
-- Supports: Tables 1 and 2, and the 0.5259 share and 76.01% overlap of §2.2
--
-- The code audit established that the score is
--
--     score = 0.3 · normalise(uplift) + 0.7 · probability
--     normalise(u) = (u − (−0.3)) / (0.8 − (−0.3))   clipped to [0, 1]
--
-- and that, because of the normalisation range, a NULL uplift already enters
-- worth 0.2727. It concluded that the EFFECTIVE weights are the inverse of the
-- declared ones, with the uplift term accounting for **94.5% of the score — in
-- one reproduced case**.
--
-- One case is not a population. The prediction history carries
-- `classic_prediction`, `uplift_prediction` and `score` on the same row, which
-- allows two things that reading the code does not:
--
--   (1) VERIFY THE FORMULA. If the stored `score` is not reproduced by the
--       expression above, the reading of the code is wrong or incomplete, and
--       the audit finding falls. The residual is the test, and it is decisive in
--       both directions.
--   (2) MEASURE THE SPLIT over 424,686 rows rather than in one example. The
--       "94.5%" claim acquires a distribution instead of being an anecdote.
--
-- Declared caution: dividing by the score is undefined when the score is zero,
-- and the split is only interpretable for a positive score. Those cases are
-- counted separately rather than dropped in silence.
-- =============================================================================

WITH calc AS (
  SELECT
    classic_prediction,
    uplift_prediction,
    score,
    -- the normalisation declared in the code, with clipping
    GREATEST(0.0, LEAST(1.0, (uplift_prediction + 0.3) / 1.1))    AS uplift_norm
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE score IS NOT NULL AND classic_prediction IS NOT NULL
    AND uplift_prediction IS NOT NULL
),
components AS (
  SELECT
    *,
    0.3 * uplift_norm                     AS uplift_term,
    0.7 * classic_prediction              AS probability_term,
    0.3 * uplift_norm + 0.7 * classic_prediction  AS reconstructed_score
  FROM calc
)
SELECT
  COUNT(*)                                                          AS rows,

  -- (1) does the formula reproduce the stored score?
  MAX(ABS(score - reconstructed_score))                             AS max_residual,
  AVG(ABS(score - reconstructed_score))                             AS mean_residual,
  COUNTIF(ABS(score - reconstructed_score) < 1e-6)                  AS matching_rows,
  SAFE_DIVIDE(COUNTIF(ABS(score - reconstructed_score) < 1e-6), COUNT(*)) AS matching_fraction,

  -- (2) the split, where it is defined
  COUNTIF(score <= 0)                                               AS non_positive_score,
  AVG(IF(score > 0, SAFE_DIVIDE(uplift_term, score), NULL))         AS mean_uplift_share,
  APPROX_QUANTILES(IF(score > 0, SAFE_DIVIDE(uplift_term, score), NULL), 10)
                                                                    AS deciles_uplift_share,

  -- the raw material, to see whether the normalisation range makes sense
  MIN(uplift_prediction)                                            AS uplift_min,
  MAX(uplift_prediction)                                            AS uplift_max,
  AVG(uplift_prediction)                                            AS uplift_mean,
  COUNTIF(uplift_prediction < 0)                                    AS uplift_negative,
  COUNTIF(uplift_prediction > 0.8)                                  AS uplift_above_ceiling,
  COUNTIF(uplift_prediction < -0.3)                                 AS uplift_below_floor,
  APPROX_QUANTILES(uplift_prediction, 10)                           AS deciles_uplift,
  MIN(classic_prediction)                                           AS probability_min,
  MAX(classic_prediction)                                           AS probability_max,
  AVG(classic_prediction)                                           AS probability_mean
FROM components;

-- Statement 2 — how many distinct values each component produces.
-- Motivated by the result of statement 1: the uplift deciles repeat values —
-- 0.10197 twice and 0.16069 three times — which is the signature of an output
-- concentrated in few atoms, as a tree with few leaves would produce. If
-- confirmed, it is the mechanism behind the massive tie rate already measured in
-- production: 12.32% of requests with a single score value, and 25.63% tying at
-- the cutoff boundary.
SELECT
  COUNT(*)                                                          AS rows,
  COUNT(DISTINCT uplift_prediction)                                 AS uplift_values,
  COUNT(DISTINCT classic_prediction)                                AS probability_values,
  COUNT(DISTINCT score)                                             AS score_values,
  SAFE_DIVIDE(COUNT(DISTINCT uplift_prediction), COUNT(*))          AS uplift_per_row
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`;

-- Statement 3 — the concentration, value by value.
SELECT
  ROUND(uplift_prediction, 6)                                       AS uplift,
  COUNT(*)                                                          AS rows,
  SAFE_DIVIDE(COUNT(*), SUM(COUNT(*)) OVER ())                      AS fraction
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
GROUP BY uplift
ORDER BY rows DESC
LIMIT 12;

-- Statement 4 — share of the SCORE is not share of the RANKING, and the
-- difference decides. Statement 1 measures how much each term contributes to the
-- MAGNITUDE of the score. But what orders a list is VARIATION, not level: a term
-- that is large and nearly constant inflates the share and moves no ranking at
-- all.
--
-- With the uplift concentrated in 28 values and the normalisation adding a fixed
-- 0.0818 to every row, the suspicion is that the uplift term is close to a
-- constant offset. The standard deviation of each term and each term's
-- correlation with the score decide it.
SELECT
  COUNT(*)                                                           AS rows,
  STDDEV(0.3 * GREATEST(0.0, LEAST(1.0, (uplift_prediction + 0.3) / 1.1)))  AS sd_uplift_term,
  STDDEV(0.7 * classic_prediction)                                   AS sd_probability_term,
  STDDEV(score)                                                      AS sd_score,
  SAFE_DIVIDE(
    STDDEV(0.3 * GREATEST(0.0, LEAST(1.0, (uplift_prediction + 0.3) / 1.1))),
    STDDEV(0.7 * classic_prediction))                                AS sd_ratio_uplift_over_probability,
  CORR(0.3 * GREATEST(0.0, LEAST(1.0, (uplift_prediction + 0.3) / 1.1)), score) AS corr_uplift_score,
  CORR(0.7 * classic_prediction, score)                              AS corr_probability_score,
  CORR(uplift_prediction, classic_prediction)                        AS corr_between_terms
FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
WHERE score IS NOT NULL AND classic_prediction IS NOT NULL AND uplift_prediction IS NOT NULL;

-- Statement 5 — the test that decides, and statement 4 alone does NOT decide.
-- A global correlation between term and score does not prove dominance WITHIN a
-- request, which is where ranking happens: a list may have similar probabilities
-- and be separated by the uplift without the global correlation noticing.
--
-- The question at the right unit: is the displayed top five the same one the
-- probability alone would produce? And the same the uplift alone would produce?
-- A declared, neutral tie-break by `deal_id` in all three cases, so that the
-- comparison is not decided by arrival order — the defect that has already
-- inverted a result four times in this project.
WITH orderings AS (
  SELECT
    tenant_id, prediction_timestamp, deal_id,
    ROW_NUMBER() OVER (PARTITION BY tenant_id, prediction_timestamp
                       ORDER BY score DESC, deal_id)              AS pos_score,
    ROW_NUMBER() OVER (PARTITION BY tenant_id, prediction_timestamp
                       ORDER BY classic_prediction DESC, deal_id) AS pos_probability,
    ROW_NUMBER() OVER (PARTITION BY tenant_id, prediction_timestamp
                       ORDER BY uplift_prediction DESC, deal_id)  AS pos_uplift,
    COUNT(*) OVER (PARTITION BY tenant_id, prediction_timestamp)  AS items
  FROM `${project_insights}.${dataset_recommendation}.${table_prediction_history}`
  WHERE score IS NOT NULL AND classic_prediction IS NOT NULL AND uplift_prediction IS NOT NULL
),
per_request AS (
  SELECT
    tenant_id, prediction_timestamp, ANY_VALUE(items) AS items,
    -- how many of the top five by score are also in the top five by probability
    COUNTIF(pos_score <= 5 AND pos_probability <= 5) AS matches_probability,
    COUNTIF(pos_score <= 5 AND pos_uplift <= 5)      AS matches_uplift,
    COUNTIF(pos_score <= 5)                          AS displayed
  FROM orderings
  GROUP BY tenant_id, prediction_timestamp
)
SELECT
  COUNT(*)                                                          AS requests,
  COUNTIF(items > 5)                                                AS requests_with_more_than_five,
  -- only where a choice exists: with five items or fewer, everything is displayed
  AVG(IF(items > 5, SAFE_DIVIDE(matches_probability, displayed), NULL)) AS mean_overlap_probability,
  AVG(IF(items > 5, SAFE_DIVIDE(matches_uplift, displayed), NULL))     AS mean_overlap_uplift,
  SAFE_DIVIDE(COUNTIF(items > 5 AND matches_probability = displayed),
              COUNTIF(items > 5))                                   AS fraction_top5_identical_to_probability,
  SAFE_DIVIDE(COUNTIF(items > 5 AND matches_uplift = displayed),
              COUNTIF(items > 5))                                   AS fraction_top5_identical_to_uplift
FROM per_request;
