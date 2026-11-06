-- =====================================================================
-- Game Revenue Metrics: monthly revenue and customer metrics
-- Database: PostgreSQL, schema "project" (GoIT course database)
-- Sources:  project.games_payments, project.games_paid_users
-- Output:   one row per user x game x month (payments or churn event),
--           with user attributes for dashboard filters.
--           Ratios (ARPPU, Churn Rate, Revenue Churn Rate) are calculated
--           in Tableau as SUM / SUM, so they react correctly to filters.
-- Author:   Vitaliia Girka (written with AI assistance, see README)
-- =====================================================================

WITH monthly_payments AS (
    -- 1. Monthly revenue per user and game
    SELECT
        gp.user_id,
        gp.game_name,
        DATE_TRUNC('month', gp.payment_date)::date
            AS payment_month,
        COUNT(*) AS payment_count,
        SUM(gp.revenue_amount_usd)
            AS monthly_revenue_usd
    FROM project.games_payments AS gp
    WHERE gp.payment_date IS NOT NULL
    GROUP BY
        gp.user_id,
        gp.game_name,
        DATE_TRUNC('month', gp.payment_date)::date
),
user_history AS (
    -- 2. First and last payment month for each user-game pair
    SELECT
        user_id,
        game_name,
        MIN(payment_month) AS first_payment_month,
        MAX(payment_month) AS last_payment_month,
        SUM(monthly_revenue_usd)
            AS total_user_revenue_usd
    FROM monthly_payments
    GROUP BY
        user_id,
        game_name
),
dataset_bounds AS (
    -- 3. First and last month in the dataset
    SELECT
        MIN(payment_month) AS dataset_first_month,
        MAX(payment_month) AS dataset_last_month
    FROM monthly_payments
),
payment_comparison AS (
    -- 4. Compare previous and next payment months
    SELECT
        mp.user_id,
        mp.game_name,
        mp.payment_month,
        mp.payment_count,
        mp.monthly_revenue_usd,
        h.first_payment_month,
        h.last_payment_month,
        h.total_user_revenue_usd,
        b.dataset_first_month,
        b.dataset_last_month,
        -- Previous calendar month
        (mp.payment_month - INTERVAL '1 month')::date
            AS previous_calendar_month,
        -- Next calendar month
        (mp.payment_month + INTERVAL '1 month')::date
            AS next_calendar_month,
        -- Previous paid month revenue
        LAG(mp.monthly_revenue_usd) OVER (
            PARTITION BY mp.user_id, mp.game_name
            ORDER BY mp.payment_month
        ) AS previous_paid_month_revenue,
        -- Previous paid month
        LAG(mp.payment_month) OVER (
            PARTITION BY mp.user_id, mp.game_name
            ORDER BY mp.payment_month
        ) AS previous_paid_month,
        -- Next paid month
        LEAD(mp.payment_month) OVER (
            PARTITION BY mp.user_id, mp.game_name
            ORDER BY mp.payment_month
        ) AS next_paid_month
    FROM monthly_payments AS mp
    JOIN user_history AS h
        ON h.user_id = mp.user_id
        AND h.game_name = mp.game_name
    CROSS JOIN dataset_bounds AS b
),
revenue_events AS (
    -- 5. Revenue metrics for months with payments
    SELECT
        pc.payment_month,
        pc.user_id,
        pc.game_name,
        pc.payment_count,
        -- 1. Monthly Recurring Revenue
        pc.monthly_revenue_usd AS mrr_usd,
        -- 2. Paid Users
        1::integer AS paid_users,
        -- 3. ARPPU
        -- Calculated in Tableau:
        -- SUM(mrr_usd) / SUM(paid_users)
        -- 4. New Paid Users
        CASE
            WHEN pc.previous_paid_month IS NULL
            THEN 1
            ELSE 0
        END AS new_paid_users,
        -- 5. New MRR
        CASE
            WHEN pc.previous_paid_month IS NULL
            THEN pc.monthly_revenue_usd
            ELSE 0::numeric
        END AS new_mrr_usd,
        -- Previous Month Paid Users
        CASE
            WHEN pc.payment_month = pc.dataset_first_month
            THEN NULL::integer
            WHEN pc.previous_paid_month =
                 pc.previous_calendar_month
            THEN 1
            ELSE 0
        END AS previous_month_paid_users,
        -- Previous Month MRR
        CASE
            WHEN pc.payment_month = pc.dataset_first_month
            THEN NULL::numeric
            WHEN pc.previous_paid_month =
                 pc.previous_calendar_month
            THEN pc.previous_paid_month_revenue
            ELSE 0::numeric
        END AS previous_month_mrr_usd,
        -- 6. Churned Users
        -- Calculated in the second part of UNION ALL
        CASE
            WHEN pc.payment_month = pc.dataset_first_month
            THEN NULL::integer
            ELSE 0
        END AS churned_users,
        -- 7. Churn Rate
        -- Calculated in Tableau
        -- 8. Churned Revenue
        CASE
            WHEN pc.payment_month = pc.dataset_first_month
            THEN NULL::numeric
            ELSE 0::numeric
        END AS churned_revenue_usd,
        -- 9. Revenue Churn Rate
        -- Calculated in Tableau
        -- 10. Expansion MRR
        CASE
            WHEN pc.previous_paid_month =
                 pc.previous_calendar_month
                AND pc.monthly_revenue_usd >
                    pc.previous_paid_month_revenue
            THEN pc.monthly_revenue_usd -
                 pc.previous_paid_month_revenue
            ELSE 0::numeric
        END AS expansion_mrr_usd,
        -- 11. Contraction MRR
        CASE
            WHEN pc.previous_paid_month =
                 pc.previous_calendar_month
                AND pc.monthly_revenue_usd <
                    pc.previous_paid_month_revenue
            THEN pc.monthly_revenue_usd -
                 pc.previous_paid_month_revenue
            ELSE 0::numeric
        END AS contraction_mrr_usd,
        -- Reactivated Paid Users
        CASE
            WHEN pc.previous_paid_month IS NOT NULL
                AND pc.previous_paid_month <>
                    pc.previous_calendar_month
            THEN 1
            ELSE 0
        END AS reactivated_paid_users,
        -- Reactivation MRR
        CASE
            WHEN pc.previous_paid_month IS NOT NULL
                AND pc.previous_paid_month <>
                    pc.previous_calendar_month
            THEN pc.monthly_revenue_usd
            ELSE 0::numeric
        END AS reactivation_mrr_usd,
        -- Monthly Revenue Change
        CASE
            WHEN pc.payment_month = pc.dataset_first_month
            THEN NULL::numeric
            WHEN pc.previous_paid_month =
                 pc.previous_calendar_month
            THEN pc.monthly_revenue_usd -
                 pc.previous_paid_month_revenue
            ELSE pc.monthly_revenue_usd
        END AS mrr_change_usd,
        -- 12. Customer Lifetime (observed months)
        CASE
            WHEN pc.payment_month = pc.last_payment_month
            THEN (
                EXTRACT(
                    YEAR FROM AGE(
                        pc.last_payment_month,
                        pc.first_payment_month
                    )
                ) * 12
                +
                EXTRACT(
                    MONTH FROM AGE(
                        pc.last_payment_month,
                        pc.first_payment_month
                    )
                )
            )::integer + 1
            ELSE NULL::integer
        END AS observed_lt_months,
        -- 13. Customer Lifetime Value (observed revenue)
        CASE
            WHEN pc.payment_month = pc.last_payment_month
            THEN pc.total_user_revenue_usd
            ELSE NULL::numeric
        END AS observed_ltv_usd
    FROM payment_comparison AS pc
    UNION ALL
    -- Add churn events to the NEXT calendar month
    SELECT
        pc.next_calendar_month AS payment_month,
        pc.user_id,
        pc.game_name,
        0::bigint AS payment_count,
        0::numeric AS mrr_usd,
        0::integer AS paid_users,
        0::integer AS new_paid_users,
        0::numeric AS new_mrr_usd,
        1::integer AS previous_month_paid_users,
        pc.monthly_revenue_usd
            AS previous_month_mrr_usd,
        1::integer AS churned_users,
        pc.monthly_revenue_usd
            AS churned_revenue_usd,
        0::numeric AS expansion_mrr_usd,
        0::numeric AS contraction_mrr_usd,
        0::integer AS reactivated_paid_users,
        0::numeric AS reactivation_mrr_usd,
        -pc.monthly_revenue_usd AS mrr_change_usd,
        NULL::integer AS observed_lt_months,
        NULL::numeric AS observed_ltv_usd
    FROM payment_comparison AS pc
    WHERE
        (
            pc.next_paid_month IS NULL
            OR pc.next_paid_month <>
               pc.next_calendar_month
        )
        AND pc.next_calendar_month <=
            pc.dataset_last_month
)
-- Final dataset for Tableau
SELECT
    e.payment_month,
    e.user_id,
    e.game_name,
    u.language,
    u.age,
    u.has_older_device_model,
    e.payment_count,
    e.mrr_usd,
    e.paid_users,
    e.new_paid_users,
    e.new_mrr_usd,
    e.previous_month_paid_users,
    e.previous_month_mrr_usd,
    e.churned_users,
    e.churned_revenue_usd,
    e.expansion_mrr_usd,
    e.contraction_mrr_usd,
    e.reactivated_paid_users,
    e.reactivation_mrr_usd,
    e.mrr_change_usd,
    e.observed_lt_months,
    e.observed_ltv_usd
FROM revenue_events AS e
JOIN project.games_paid_users AS u
    ON u.user_id = e.user_id
    AND u.game_name = e.game_name
ORDER BY
    e.payment_month,
    e.game_name,
    e.user_id;