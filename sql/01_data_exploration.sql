-- =====================================================================
-- Game Revenue Metrics: data exploration and quality checks
-- Database: PostgreSQL, schema "project" (GoIT course database)
-- Purpose: understand the grain, period and quality of the data
--          before writing the metrics query.
-- Results of the checks are summarised at the end of the file.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Users table: is one row = one user?
-- If rows > users, the later JOIN to payments will DUPLICATE revenue.
-- RECORD: rows, distinct users, distinct (user, game) pairs
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                AS row_count,
    COUNT(DISTINCT user_id) AS user_count,
    (SELECT COUNT(*)
     FROM (SELECT DISTINCT user_id, game_name
           FROM project.games_paid_users) AS ug) AS user_game_count
FROM project.games_paid_users;


-- ---------------------------------------------------------------------
-- 2. Payments: period covered, volume, suspicious amounts
-- RECORD: first/last payment date, nulls, zero/negative amounts
-- ---------------------------------------------------------------------
SELECT
    MIN(payment_date)                                        AS first_payment,
    MAX(payment_date)                                        AS last_payment,
    COUNT(*)                                                 AS payment_rows,
    COUNT(DISTINCT user_id)                                  AS paying_users,
    SUM(CASE WHEN revenue_amount_usd IS NULL THEN 1 ELSE 0 END) AS null_amounts,
    SUM(CASE WHEN revenue_amount_usd <= 0    THEN 1 ELSE 0 END) AS non_positive_amounts,
    SUM(CASE WHEN payment_date IS NULL       THEN 1 ELSE 0 END) AS null_dates
FROM project.games_payments;


-- ---------------------------------------------------------------------
-- 3. Monthly overview — the first draft of MRR and Paid Users
-- Look at the LAST month: is it complete? (max_date_in_month near the
-- end of the month?) A partial last month looks like a revenue drop
-- and makes every user look "churned" in the month after.
-- RECORD: number of months, is the last month complete?
-- ---------------------------------------------------------------------
SELECT
    DATE_TRUNC('month', payment_date)::date AS payment_month,
    COUNT(*)                                AS payment_rows,
    COUNT(DISTINCT user_id)                 AS paid_users,
    SUM(revenue_amount_usd)                 AS revenue,
    MAX(payment_date)                       AS max_date_in_month
FROM project.games_payments
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 4. Grain check: can a user pay several times in one month?
-- If yes, the metrics query must first aggregate to user x month.
-- RECORD: user-months total vs user-months with >1 payment
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                   AS user_months,
    SUM(CASE WHEN n_payments > 1 THEN 1 ELSE 0 END) AS user_months_with_multiple_payments
FROM (
    SELECT user_id,
           DATE_TRUNC('month', payment_date) AS payment_month,
           COUNT(*)                          AS n_payments
    FROM project.games_payments
    GROUP BY 1, 2
) AS um;


-- ---------------------------------------------------------------------
-- 5. Do the two tables match?
-- RECORD: payers missing from users table; users with no payments
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(DISTINCT p.user_id)
     FROM project.games_payments AS p
     LEFT JOIN project.games_paid_users AS u ON u.user_id = p.user_id
     WHERE u.user_id IS NULL) AS payers_without_profile,
    (SELECT COUNT(DISTINCT u.user_id)
     FROM project.games_paid_users AS u
     LEFT JOIN project.games_payments AS p ON p.user_id = u.user_id
     WHERE p.user_id IS NULL) AS profiles_without_payments;


-- ---------------------------------------------------------------------
-- 6. Filter dimensions: what values will the dashboard filters show?
-- RECORD: list of languages, age range, NULLs, odd values
-- ---------------------------------------------------------------------
SELECT language, COUNT(*) AS users
FROM project.games_paid_users
GROUP BY 1
ORDER BY 2 DESC;

SELECT
    MIN(age) AS min_age,
    MAX(age) AS max_age,
    ROUND(AVG(age), 1) AS avg_age,
    SUM(CASE WHEN age IS NULL THEN 1 ELSE 0 END) AS null_age
FROM project.games_paid_users;


-- ---------------------------------------------------------------------
-- 7. Do users skip months and come back? (reactivation)
-- The course churn logic counts such a user as churned, and when they
-- return they are neither "new" nor "expansion". If this number is
-- not zero, we need a "Reactivated MRR" category, otherwise the
-- monthly revenue change will not add up.
-- RECORD: first payments vs consecutive months vs returns after a gap
-- ---------------------------------------------------------------------
WITH user_months AS (
    SELECT DISTINCT
           user_id,
           DATE_TRUNC('month', payment_date)::date AS payment_month
    FROM project.games_payments
),
with_prev AS (
    SELECT user_id,
           payment_month,
           LAG(payment_month) OVER (PARTITION BY user_id ORDER BY payment_month) AS prev_payment_month
    FROM user_months
)
SELECT
    SUM(CASE WHEN prev_payment_month IS NULL THEN 1 ELSE 0 END) AS first_payment_months,
    SUM(CASE WHEN prev_payment_month = (payment_month - INTERVAL '1 month')::date
             THEN 1 ELSE 0 END)                                 AS consecutive_months,
    SUM(CASE WHEN prev_payment_month < (payment_month - INTERVAL '1 month')::date
             THEN 1 ELSE 0 END)                                 AS returns_after_gap
FROM with_prev;



-- =====================================================================
-- RESULTS (run on 2026-10-12)
-- 1. games_paid_users: 383 rows = 383 users = 383 (user, game) pairs
--    -> one row per user, JOIN on user_id is safe (no fan-out).
-- 2. Payments 2022-03-01 .. 2022-12-31, 3,026 rows, 383 payers,
--    no NULLs, no zero/negative amounts.
-- 3. 10 months (Mar-Dec 2022), every month complete (data to the 31st).
--    -> Jan 2023 is NOT observed: December payers must not be counted
--       as churned (censoring). March: all users look "new" because
--       data starts there (possible left-censoring).
-- 4. 1,392 user-months, 821 (59%) with >1 payment
--    -> aggregate to user x month BEFORE any LAG/LEAD.
-- 5. Tables match 100% (0 payers without profile, 0 profiles w/o pay).
-- 6. Languages: uk 266, ru 109, en 8 (en = tiny sample).
--    Age 14-44, avg 23.3, no NULLs.
-- 7. User-months: 383 first + 857 consecutive + 152 after a gap = 1,392
--    (reconciles with block 4). 152 reactivations (~11%)
--    -> need a "Reactivated MRR / users" category for the change bridge.
-- =====================================================================

