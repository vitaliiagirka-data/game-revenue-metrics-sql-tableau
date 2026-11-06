-- =====================================================================
-- Game Revenue Metrics: validation checks (PostgreSQL)
-- Prerequisite: run 02_revenue_metrics.sql as a CREATE TEMP TABLE:
--
--   CREATE TEMP TABLE revenue_metrics AS
--   <the SELECT query from 02_revenue_metrics.sql without its ORDER BY>;
--
-- This file does not create the temporary table automatically.
-- Expected outcomes:
--   1. Exactly 1,738 rows (course dataset).
--   2-4. Zero returned rows (no discrepancies).
-- Reconciliation checks 3-4 cover APRIL-DECEMBER, not March:
-- March is the first observed month, and prior-period churn is undefined.
-- =====================================================================

-- 1. Row count: 1,392 payment user-months + 346 churn event rows.
SELECT COUNT(*) AS row_count
FROM revenue_metrics;

-- 2. Uniqueness: no duplicate user x game x calendar-month records.
-- Expected: 0 rows.
SELECT user_id, game_name, payment_month, COUNT(*) AS row_count
FROM revenue_metrics
GROUP BY user_id, game_name, payment_month
HAVING COUNT(*) > 1;

-- 3. Monthly revenue and paying users match the raw payments.
-- FULL OUTER JOIN also catches a month missing from either side.
-- Expected: 0 rows.
WITH raw_totals AS (
    SELECT
        DATE_TRUNC('month', payment_date)::date AS payment_month,
        SUM(revenue_amount_usd) AS raw_revenue_usd,
        COUNT(DISTINCT user_id) AS raw_paid_users
    FROM project.games_payments
    GROUP BY 1
),
model_totals AS (
    SELECT
        payment_month,
        SUM(mrr_usd) AS model_revenue_usd,
        SUM(paid_users) AS model_paid_users
    FROM revenue_metrics
    GROUP BY 1
)
SELECT
    COALESCE(r.payment_month, m.payment_month) AS payment_month,
    r.raw_revenue_usd,
    m.model_revenue_usd,
    r.raw_paid_users,
    m.model_paid_users
FROM raw_totals AS r
FULL OUTER JOIN model_totals AS m
    ON r.payment_month = m.payment_month
WHERE r.payment_month IS NULL
   OR m.payment_month IS NULL
   OR r.raw_revenue_usd IS DISTINCT FROM m.model_revenue_usd
   OR r.raw_paid_users IS DISTINCT FROM m.model_paid_users
ORDER BY payment_month;

-- 4. Month-over-month bridges + churn base (April-December).
-- Expected: 0 rows. March deliberately excluded after LAG is calculated.
WITH monthly AS (
    SELECT
        payment_month,
        SUM(mrr_usd) AS mrr_usd,
        SUM(paid_users) AS paid_users,
        SUM(new_mrr_usd) AS new_mrr_usd,
        SUM(reactivation_mrr_usd) AS reactivation_mrr_usd,
        SUM(expansion_mrr_usd) AS expansion_mrr_usd,
        SUM(contraction_mrr_usd) AS contraction_mrr_usd,
        SUM(churned_revenue_usd) AS churned_revenue_usd,
        SUM(new_paid_users) AS new_paid_users,
        SUM(reactivated_paid_users) AS reactivated_paid_users,
        SUM(churned_users) AS churned_users,
        SUM(previous_month_paid_users) AS churn_rate_base
    FROM revenue_metrics
    GROUP BY payment_month
),
comparison AS (
    SELECT
        payment_month,
        mrr_usd - LAG(mrr_usd) OVER (ORDER BY payment_month)
            AS actual_mrr_change,
        new_mrr_usd + reactivation_mrr_usd + expansion_mrr_usd
            + contraction_mrr_usd - churned_revenue_usd
            AS explained_mrr_change,
        paid_users - LAG(paid_users) OVER (ORDER BY payment_month)
            AS actual_paid_users_change,
        new_paid_users + reactivated_paid_users - churned_users
            AS explained_paid_users_change,
        LAG(paid_users) OVER (ORDER BY payment_month)
            AS actual_previous_month_paid_users,
        churn_rate_base
    FROM monthly
)
SELECT *
FROM comparison
WHERE payment_month > (SELECT MIN(payment_month) FROM monthly)
  AND (
       actual_mrr_change IS DISTINCT FROM explained_mrr_change
    OR actual_paid_users_change IS DISTINCT FROM explained_paid_users_change
    OR actual_previous_month_paid_users IS DISTINCT FROM churn_rate_base
  )
ORDER BY payment_month;
