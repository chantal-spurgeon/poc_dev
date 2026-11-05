# Personal Cortex AI usage dashboard — resolves viewer via Snowflake SPCS proxy header.
# Co-authored with CoCo
import streamlit as st
from snowflake.snowpark.context import get_active_session
import pandas as pd

st.set_page_config(page_title="My Cortex AI Usage", layout="wide")
st.title("My Cortex AI Usage")
st.caption("Personal AI credit consumption dashboard — filtered to your account")

session = get_active_session()

def run_query(sql):
    return session.sql(sql).to_pandas()

# In Snowflake Container Runtime (SPCS), the proxy injects the viewer's Snowflake
# username into the "Sf-Context-Current-User" request header. Neither CURRENT_USER()
# nor st.experimental_user work — they both reflect the service account.
def _resolve_viewer() -> str:
    try:
        headers = st.context.headers  # available in Streamlit ≥ 1.31
        user = (
            headers.get("Sf-Context-Current-User")
            or headers.get("sf-context-current-user")
        )
        if user:
            return user
    except Exception:
        pass
    return session.sql("SELECT CURRENT_USER()").collect()[0][0]

current_user = _resolve_viewer()
_display_user = current_user.split("@")[0] if "@" in current_user else current_user
st.sidebar.markdown(f"**User:** {_display_user}")
st.sidebar.markdown(f"**Month:** {pd.Timestamp.now().strftime('%B %Y')}")


MODEL_RATES_CTE = """
model_rates AS (
    SELECT column1 AS model_name, column2 AS input_rate, column3 AS output_rate
    FROM VALUES
        ('claude-4-sonnet', 1.50, 7.50),
        ('claude-sonnet-4-5', 1.50, 7.50),
        ('claude-sonnet-4-6', 1.50, 7.50),
        ('claude-sonnet-5', 1.00, 5.00),
        ('claude-haiku-4-5', 0.50, 2.50),
        ('claude-opus-4-5', 2.50, 12.50),
        ('claude-opus-4-6', 2.50, 12.50),
        ('claude-opus-4-7', 2.50, 12.50),
        ('openai-gpt-4.1', 1.00, 4.00),
        ('openai-gpt-5', 0.625, 5.00),
        ('openai-gpt-5-mini', 0.125, 1.00),
        ('openai-gpt-5-nano', 0.03, 0.22),
        ('openai-gpt-5.1', 0.625, 5.00),
        ('openai-gpt-5.4', 1.25, 7.50),
        ('grok-4.20', 0.625, 1.25),
        ('llama3.1-405b', 1.20, 1.20),
        ('llama3.1-70b', 0.36, 0.36),
        ('llama3.3-70b', 0.36, 0.36),
        ('llama4-maverick', 0.144, 0.582),
        ('llama4-scout', 0.102, 0.396),
        ('mistral-large2', 1.00, 3.00),
        ('deepseek-r1', 0.675, 2.70),
        ('snowflake-llama-3.3-70b', 0.36, 0.36)
)
"""

tab1, tab2, tab3, tab4 = st.tabs([
    "My Usage This Month",
    "Activity Detail",
    "My REST API Usage",
    "Tips & Cost Guidance"
])

# ============================================================
# TAB 1: My Usage This Month
# ============================================================
with tab1:
    st.header("My Usage This Month")

    my_quota_limit = st.sidebar.number_input("My monthly quota (credits)", min_value=1, value=50, key="my_limit",
                                              help="AI_EXPLORER tier limit. AI_DATA_SCIENCE tier limit is 200. Ask your admin if unsure.")

    summary_query = f"""
    SELECT SERVICE_TYPE, COALESCE(SUM(CREDITS), 0) AS TOTAL_CREDITS FROM (
        SELECT 'CoCo CLI' AS SERVICE_TYPE, TOKEN_CREDITS AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY
        WHERE USER_NAME = '{current_user}'
          AND USAGE_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
        UNION ALL
        SELECT 'CoCo Desktop', TOKEN_CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY
        WHERE USER_NAME = '{current_user}'
          AND USAGE_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
        UNION ALL
        SELECT 'CoCo Snowsight', TOKEN_CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY
        WHERE USER_NAME = '{current_user}'
          AND USAGE_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
        UNION ALL
        SELECT 'AI Functions', h.CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
        JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
        WHERE u.NAME = '{current_user}'
          AND h.START_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
        UNION ALL
        SELECT 'Cortex Agents', TOKEN_CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
        WHERE USER_NAME = '{current_user}'
          AND START_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
        UNION ALL
        SELECT 'CoWork / Intelligence', TOKEN_CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY
        WHERE USER_NAME = '{current_user}'
          AND START_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
    )
    GROUP BY SERVICE_TYPE
    ORDER BY TOTAL_CREDITS DESC
    """

    with st.spinner("Loading my usage..."):
        df_summary = run_query(summary_query)
        total_credits = df_summary["TOTAL_CREDITS"].sum() if not df_summary.empty else 0
        pct_used = (total_credits / my_quota_limit) * 100 if my_quota_limit > 0 else 0
        days_in_month = pd.Timestamp.now().days_in_month
        day_of_month = pd.Timestamp.now().day
        daily_avg = total_credits / max(day_of_month, 1)

        col1, col2, col3 = st.columns(3)
        with col1:
            st.metric("Total Credits Used", f"{total_credits:.4f}")
        with col2:
            st.metric("Daily Average", f"{daily_avg:.4f}")
        with col3:
            st.metric("Quota Used", f"{pct_used:.1f}%")

        st.progress(min(pct_used / 100, 1.0), text=f"{total_credits:.2f} / {my_quota_limit} credits")

        if not df_summary.empty:
            st.subheader("Breakdown by Service")
            st.bar_chart(df_summary.set_index("SERVICE_TYPE")["TOTAL_CREDITS"])
            st.dataframe(df_summary, use_container_width=True)
        else:
            st.info("No usage recorded for you this month.")

    # REST API addition
    st.divider()
    st.subheader("REST API (Not Covered by Quota)")
    rest_summary_query = f"""
    WITH {MODEL_RATES_CTE}
    SELECT ROUND(SUM(
        (COALESCE(r.TOKENS_GRANULAR:"input"::INT, 0) / 1000000.0) * COALESCE(mr.input_rate, 0)
        + (COALESCE(r.TOKENS_GRANULAR:"output"::INT, 0) / 1000000.0) * COALESCE(mr.output_rate, 0)
    ), 6) AS EST_CREDITS
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY r
    LEFT JOIN model_rates mr ON LOWER(r.MODEL_NAME) = LOWER(mr.model_name)
    JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON r.USER_ID = u.USER_ID
    WHERE u.NAME = '{current_user}'
      AND r.START_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
    """
    try:
        df_rest_sum = run_query(rest_summary_query)
        rest_credits = df_rest_sum["EST_CREDITS"].iloc[0] if not df_rest_sum.empty and df_rest_sum["EST_CREDITS"].iloc[0] else 0
        st.metric("REST API Estimated Credits (this month)", f"{rest_credits:.4f}")
        st.caption("REST API credits are tracked separately and enforced via role revocation, not per-user quotas.")
    except Exception:
        st.info("No REST API usage found.")

# ============================================================
# TAB 2: Activity Detail
# ============================================================
with tab2:
    st.header("My Activity Detail")
    days_detail = st.slider("Days to show", 7, 30, 14, key="detail_days")

    if st.button("Load My Activity", key="load_activity"):
        with st.spinner("Loading..."):
            detail_query = f"""
            SELECT * FROM (
                SELECT 'CoCo CLI' AS SURFACE, USAGE_TIME::DATE AS USAGE_DATE, TOKEN_CREDITS AS CREDITS, TOKENS
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY
                WHERE USER_NAME = '{current_user}'
                  AND USAGE_TIME >= DATEADD('day', -{days_detail}, CURRENT_TIMESTAMP())
                UNION ALL
                SELECT 'CoCo Desktop', USAGE_TIME::DATE, TOKEN_CREDITS, TOKENS
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY
                WHERE USER_NAME = '{current_user}'
                  AND USAGE_TIME >= DATEADD('day', -{days_detail}, CURRENT_TIMESTAMP())
                UNION ALL
                SELECT 'CoCo Snowsight', USAGE_TIME::DATE, TOKEN_CREDITS, TOKENS
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY
                WHERE USER_NAME = '{current_user}'
                  AND USAGE_TIME >= DATEADD('day', -{days_detail}, CURRENT_TIMESTAMP())
            )
            ORDER BY USAGE_DATE DESC
            """
            df_detail = run_query(detail_query)
            if df_detail.empty:
                st.info("No CoCo activity found.")
            else:
                daily_trend = df_detail.groupby("USAGE_DATE")["CREDITS"].sum().reset_index()
                st.line_chart(daily_trend.set_index("USAGE_DATE"))
                st.dataframe(df_detail, use_container_width=True)

        st.divider()
        st.subheader("AI Functions I've Used")
        ai_func_query = f"""
        SELECT h.FUNCTION_NAME, h.MODEL_NAME, ROUND(SUM(h.CREDITS), 4) AS TOTAL_CREDITS, COUNT(*) AS CALL_COUNT
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
        JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
        WHERE u.NAME = '{current_user}'
          AND h.START_TIME >= DATEADD('day', -{days_detail}, CURRENT_TIMESTAMP())
        GROUP BY 1, 2
        ORDER BY TOTAL_CREDITS DESC
        """
        df_funcs = run_query(ai_func_query)
        if df_funcs.empty:
            st.info("No AI function usage found.")
        else:
            st.dataframe(df_funcs, use_container_width=True)

# ============================================================
# TAB 3: My REST API Usage
# ============================================================
with tab3:
    st.header("My REST API Usage")
    st.warning("REST API is NOT covered by Per-User Quotas. It is tracked and enforced separately.")

    if st.button("Load My REST API Calls", key="load_my_rest"):
        with st.spinner("Loading..."):
            my_rest_query = f"""
            WITH {MODEL_RATES_CTE}
            SELECT
                r.MODEL_NAME,
                r.INFERENCE_REGION,
                COUNT(*) AS REQUEST_COUNT,
                SUM(r.TOKENS) AS TOTAL_TOKENS,
                SUM(COALESCE(r.TOKENS_GRANULAR:"input"::INT, 0)) AS INPUT_TOKENS,
                SUM(COALESCE(r.TOKENS_GRANULAR:"output"::INT, 0)) AS OUTPUT_TOKENS,
                ROUND(SUM(
                    (COALESCE(r.TOKENS_GRANULAR:"input"::INT, 0) / 1000000.0) * COALESCE(mr.input_rate, 0)
                    + (COALESCE(r.TOKENS_GRANULAR:"output"::INT, 0) / 1000000.0) * COALESCE(mr.output_rate, 0)
                ), 6) AS ESTIMATED_CREDITS
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY r
            LEFT JOIN model_rates mr ON LOWER(r.MODEL_NAME) = LOWER(mr.model_name)
            JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON r.USER_ID = u.USER_ID
            WHERE u.NAME = '{current_user}'
              AND r.START_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
            GROUP BY 1, 2
            ORDER BY ESTIMATED_CREDITS DESC
            """
            df_my_rest = run_query(my_rest_query)
            if df_my_rest.empty:
                st.info("No REST API usage this month.")
            else:
                total_est = df_my_rest["ESTIMATED_CREDITS"].sum()
                st.metric("My Total REST API Credits (estimated)", f"{total_est:.4f}")
                st.dataframe(df_my_rest, use_container_width=True)

# ============================================================
# TAB 4: Tips & Cost Guidance
# ============================================================
with tab4:
    st.header("Tips & Cost Guidance")

    st.subheader("What drives cost?")
    st.markdown("""
    Context handling (not model choice) is the dominant cost driver for CoCo usage.
    Each request sends context (files, conversation history, tool results) to the model.
    Larger context = more tokens = more credits.

    The most impactful thing you can do:
    - Scope your prompts tightly
    - Add this to your instructions: "If a permission error occurs, stop and tell me which object and role are involved."
    - Avoid open-ended exploration ("fix everything") in favor of specific tasks
    """)

    st.subheader("Model Selection")
    st.markdown("""
    When using AI Functions directly (AI_COMPLETE, etc.), cheaper models work fine for simpler tasks:
    - Simple classification/extraction: llama3.1-8b, mistral-7b (cheapest)
    - General tasks: llama3.3-70b, openai-gpt-5-mini
    - Complex reasoning: claude-sonnet-4-5, openai-gpt-5 (more expensive)
    - CoCo model selection is automatic; you cannot control it directly
    """)

    st.subheader("Understanding Your Quota")
    st.markdown("""
    Per-User Quotas cover: AI Functions, CoCo (all surfaces), Cortex Agents, and CoWork.

    When you hit your daily or monthly limit, Snowflake blocks new AI requests until:
    - Daily limit: resets at midnight UTC
    - Monthly limit: resets on the 1st of the month

    REST API calls are tracked separately and have their own limit managed by your admin.
    """)

    st.subheader("Request a Tier Upgrade")
    st.markdown("If you consistently hit your limit and have a business justification, send this to your admin:")
    st.code(f"""Hi [Admin],

I am hitting my per-user AI quota limit ({my_quota_limit} credits/month).
My current usage is primarily [describe: CoCo development / AI functions for pipeline / etc.].
I would like to request an upgrade from my current tier to [standard/power].

Business justification: [describe project or use case]

Thank you,
{current_user}
""", language="text")

    st.divider()
    st.subheader("Reference Links")
    st.markdown("""
    - Per-User Quotas: https://docs.snowflake.com/en/user-guide/budgets/per-user-quotas
    - Cost Attribution: https://docs.snowflake.com/en/user-guide/cost-attributing
    - Credit Consumption Table: https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf
    """)
