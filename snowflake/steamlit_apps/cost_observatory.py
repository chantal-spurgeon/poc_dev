"""
Snowflake Cost Explorer
------------------------
A Streamlit app for monitoring and breaking down monthly Snowflake costs by
category (compute, storage, AI/Cortex, replication, egress), with drill-downs
by warehouse, query tag, user, and role (with optional department rollups).

AI Services costs are sourced from Snowflake's dedicated Cortex Account Usage
views (CORTEX_AI_FUNCTIONS_USAGE_HISTORY, CORTEX_ANALYST_USAGE_HISTORY,
CORTEX_AGENT_USAGE_HISTORY) rather than inferred from QUERY_HISTORY text
matching, giving real per-call credit/token figures. User/query tag/role
attribution on Cortex usage is only available for usage on or after
2026-02-16; earlier usage is included in totals but shown as "unattributed"
in the user/role breakdowns.

Data source: SNOWFLAKE.ACCOUNT_USAGE views (requires ACCOUNTADMIN or a role
granted the IMPORTED PRIVILEGES on the SNOWFLAKE database, or the
ORGANIZATION_USAGE-equivalent grants for ACCOUNT_USAGE).

This app is designed to run in EITHER of two modes, auto-detected at startup:
  1. Streamlit in Snowflake (SiS) — deployed via CREATE STREAMLIT and opened
     in Snowsight. Uses the app's own active session automatically; no
     credentials needed. See README.md for deployment steps.
  2. Standalone / local — run with `streamlit run app.py` outside Snowflake.
     Uses a login form in the sidebar (or demo data with no connection at
     all) to build a Snowpark session.

Run standalone with:
    streamlit run app.py
"""

import datetime as dt
from dataclasses import dataclass

import pandas as pd
import plotly.express as px
import streamlit as st

# --------------------------------------------------------------------------
# Page config
# --------------------------------------------------------------------------
st.set_page_config(
    page_title="Snowflake Cost Observatory",
    page_icon="❄️",
    layout="wide",
)

CATEGORY_COLORS = {
    "Compute": "#29B5E8",
    "Storage": "#1A6E8E",
    "AI Services": "#7D44CF",
    "Replication": "#F2A900",
    "Egress": "#E8586C",
    "Other Serverless": "#5C9E31",
    "Cloud Services": "#8A8F98",
    "Other": "#B7BDC6",
}

CATEGORY_ORDER = list(CATEGORY_COLORS.keys())


# --------------------------------------------------------------------------
# Connection handling
#
# Supports two run modes:
#  - Streamlit in Snowflake (SiS): an active Snowpark session already exists
#    and is retrieved via get_active_session() — no login needed.
#  - Standalone: a Snowpark Session is built from sidebar-entered credentials
#    and cached in st.session_state.
# --------------------------------------------------------------------------
@st.cache_resource(show_spinner=False)
def get_sis_session():
    """Return the active Snowpark session if running inside Streamlit in
    Snowflake, else None. Cached as a resource since it's a live connection
    object and only needs to be fetched once per app instance."""
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        return None


def get_session():
    """Return (session, is_sis) — the active Snowpark session to use, and
    whether it came from running natively inside Streamlit in Snowflake."""
    sis_session = get_sis_session()
    if sis_session is not None:
        return sis_session, True
    return st.session_state.get("sf_session"), False


def try_connect(account, user, password, role, warehouse, authenticator):
    """Build a Snowpark session for standalone/local use (not needed inside SiS)."""
    from snowflake.snowpark import Session

    conn_params = dict(
        account=account,
        user=user,
        role=role or None,
        warehouse=warehouse or None,
    )
    if authenticator == "Password":
        conn_params["password"] = password
    else:
        conn_params["authenticator"] = "externalbrowser"

    return Session.builder.configs(conn_params).create()


def run_query(session, sql, params=None):
    """Run a query via a Snowpark session and return a pandas DataFrame.
    SQL text should use `?` placeholders; params is a positional list."""
    return session.sql(sql, params=params).to_pandas()


@st.cache_data(ttl=900, show_spinner=False)
def cached_query(_session, sql, params=None, cache_key=None):
    """Wrapper so Streamlit can cache on cache_key while _session is unhashed."""
    df = run_query(_session, sql, params)
    return normalize_date_column(df)


def normalize_date_column(df, col="DATE"):
    """Coerce a DATE-like column to timezone-naive datetimes.

    Snowflake's ACCOUNT_USAGE views mix column types: TIMESTAMP_LTZ columns
    (e.g. START_TIME, and anything derived from it like DATE_TRUNC('day',
    START_TIME)) come back timezone-aware via Snowpark, while plain DATE
    columns (e.g. STORAGE_USAGE.USAGE_DATE) come back timezone-naive.
    Concatenating/parsing those together later raises "Cannot mix tz-aware
    with tz-naive values", so every live query result is normalized to
    naive here, right at the source, before it's used anywhere else."""
    if df is None or df.empty or col not in df.columns:
        return df
    df = df.copy()
    df[col] = pd.to_datetime(df[col], utc=True).dt.tz_localize(None)
    return df


# --------------------------------------------------------------------------
# Mock data (used when there's no live connection, so the app is demoable)
# --------------------------------------------------------------------------
@st.cache_data(ttl=3600)
def generate_mock_data(start_date, end_date, seed=42):
    import numpy as np

    rng = np.random.default_rng(seed)
    days = pd.date_range(start_date, end_date, freq="D")

    warehouses = ["ETL_WH", "BI_WH", "ADHOC_WH", "DS_WH", "LOAD_WH"]
    users = ["jsmith", "svc_etl", "adiaz", "mchen", "svc_bi", "kwright"]
    tags = ["dbt_run", "ad_hoc", "dashboard_refresh", "ml_training", None]
    roles = [
        "FINANCE_ANALYST", "FINANCE_ADMIN",
        "MARKETING_ANALYST", "MARKETING_ADMIN",
        "DATA_ENGINEER", "SYSADMIN",
    ]

    # Compute (warehouse metering) rows
    compute_rows = []
    for d in days:
        for wh in warehouses:
            base = {"ETL_WH": 12, "BI_WH": 8, "ADHOC_WH": 4, "DS_WH": 6, "LOAD_WH": 5}[wh]
            credits = max(0, rng.normal(base, base * 0.25))
            compute_rows.append({"DATE": d, "WAREHOUSE_NAME": wh, "CREDITS": credits})
    compute_df = pd.DataFrame(compute_rows)

    # Query history rows (for user / tag / role / warehouse slicing)
    query_rows = []
    for d in days:
        n_queries = rng.integers(80, 200)
        for _ in range(n_queries):
            wh = rng.choice(warehouses)
            user = rng.choice(users)
            tag = rng.choice(tags)
            role = rng.choice(roles)
            credits = abs(rng.normal(0.05, 0.04))
            query_rows.append(
                {
                    "DATE": d,
                    "WAREHOUSE_NAME": wh,
                    "USER_NAME": user,
                    "QUERY_TAG": tag,
                    "ROLE_NAME": role,
                    "CREDITS_ATTRIBUTED": credits,
                }
            )
    query_df = pd.DataFrame(query_rows)

    # Cortex AI Functions usage rows (CORTEX_AI_FUNCTIONS_USAGE_HISTORY style).
    # User/query tag/role attribution is only available for usage on/after
    # 2026-02-16, so mimic that cutoff for realism.
    attribution_cutoff = dt.date(2026, 2, 16)
    functions = ["COMPLETE", "TRANSLATE", "SUMMARIZE", "EMBED_TEXT_1024", "AI_PARSE_DOCUMENT", "AI_CLASSIFY"]
    models = ["llama3.1-70b", "mistral-large2", "snowflake-arctic", "claude-sonnet-4-5", None]
    cortex_rows = []
    for d in days:
        n_calls = rng.integers(20, 90)
        is_attributed = d.date() >= attribution_cutoff if hasattr(d, "date") else True
        for _ in range(n_calls):
            fn = rng.choice(functions)
            model = rng.choice(models) if fn != "AI_PARSE_DOCUMENT" else None
            wh = rng.choice(warehouses)
            credits = abs(rng.normal(0.02, 0.015))
            tokens = int(abs(rng.normal(1500, 800)))
            cortex_rows.append(
                {
                    "DATE": d,
                    "WAREHOUSE_NAME": wh,
                    "USER_NAME": rng.choice(users) if is_attributed else None,
                    "QUERY_TAG": rng.choice(tags) if is_attributed else None,
                    "ROLE_NAME": rng.choice(roles) if is_attributed else None,
                    "FUNCTION_NAME": fn,
                    "MODEL_NAME": model,
                    "TOKENS": tokens,
                    "CREDITS": credits,
                    "SOURCE": "Cortex AI Functions",
                }
            )
        # Cortex Code ("CoCo") usage across CLI / Snowsight / Desktop — no
        # warehouse or query tag concept, but does have user/role.
        for source_label, n_range in [
            ("Cortex Code (CLI)", (5, 20)),
            ("Cortex Code (Snowsight)", (3, 15)),
            ("Cortex Code (Desktop)", (1, 8)),
        ]:
            for _ in range(rng.integers(*n_range)):
                credits = abs(rng.normal(0.015, 0.01))
                tokens = int(abs(rng.normal(2000, 1000)))
                cortex_rows.append(
                    {
                        "DATE": d,
                        "WAREHOUSE_NAME": None,
                        "USER_NAME": rng.choice(users),
                        "QUERY_TAG": None,
                        "ROLE_NAME": rng.choice(roles),
                        "FUNCTION_NAME": source_label,
                        "MODEL_NAME": None,
                        "TOKENS": tokens,
                        "CREDITS": credits,
                        "SOURCE": source_label,
                    }
                )
    cortex_df = pd.DataFrame(cortex_rows)


    # Storage (roughly steady, slow growth), split into regular (active table
    # + stage bytes) and Fail-safe (recently deleted data still billed during
    # the Fail-safe retention window — typically ~7-10% of active storage).
    storage_rows = []
    base_tb = 40
    for i, d in enumerate(days):
        active_tb = max(base_tb + i * 0.05 + rng.normal(0, 0.3), 0)
        failsafe_tb = max(active_tb * 0.08 + rng.normal(0, 0.5), 0)
        storage_rows.append(
            {
                "DATE": d,
                "ACTIVE_TB": active_tb,
                "FAILSAFE_TB": failsafe_tb,
                "STORAGE_TB": active_tb + failsafe_tb,
            }
        )
    storage_df = pd.DataFrame(storage_rows)

    # Replication
    repl_rows = [
        {"DATE": d, "CREDITS": max(0, rng.normal(1.5, 0.6))} for d in days
    ]
    repl_df = pd.DataFrame(repl_rows)

    # Egress (data transfer), priced separately (in GB, converted to $ later)
    egress_rows = [
        {"DATE": d, "BYTES_TRANSFERRED": max(0, rng.normal(50, 20)) * 1e9}
        for d in days
    ]
    egress_df = pd.DataFrame(egress_rows)

    # Service-type breakdown (METERING_DAILY_HISTORY style). This view has no
    # per-object NAME column — it's SERVICE_TYPE totals for the whole account,
    # per day. WAREHOUSE_METERING here mirrors compute_df's totals summed
    # across all warehouses; the other service types represent "serverless"
    # compute-adjacent features that aren't captured by
    # WAREHOUSE_METERING_HISTORY at all. CORTEX_CODE_* represents Cortex Code
    # ("CoCo") usage across the CLI/Desktop/Snowsight surfaces.
    service_type_rows = []
    for d in days:
        wh_total = sum(
            max(0, rng.normal(base, base * 0.25))
            for base in {"ETL_WH": 12, "BI_WH": 8, "ADHOC_WH": 4, "DS_WH": 6, "LOAD_WH": 5}.values()
        )
        service_type_rows.append({"DATE": d, "SERVICE_TYPE": "WAREHOUSE_METERING", "CREDITS": wh_total})
        serverless_services = {
            "AUTOMATIC_CLUSTERING": 1.2,
            "MATERIALIZED_VIEW": 0.6,
            "SEARCH_OPTIMIZATION": 0.8,
            "QUERY_ACCELERATION": 0.4,
            "SNOWPIPE": 0.5,
            "CORTEX_CODE_SNOWSIGHT": 0.9,
            "CORTEX_CODE_CLI": 0.7,
            "CORTEX_CODE_DESKTOP": 0.3,
        }
        for svc, base in serverless_services.items():
            credits = max(0, rng.normal(base, base * 0.4))
            service_type_rows.append({"DATE": d, "SERVICE_TYPE": svc, "CREDITS": credits})
    service_type_df = pd.DataFrame(service_type_rows)

    return {
        "compute": compute_df,
        "query": query_df,
        "cortex": cortex_df,
        "storage": storage_df,
        "replication": repl_df,
        "egress": egress_df,
        "service_type": service_type_df,
        "_diagnostics": [],
    }


# --------------------------------------------------------------------------
# Live data loaders (ACCOUNT_USAGE queries)
# --------------------------------------------------------------------------
def load_live_data(conn, start_date, end_date):
    params = [start_date, end_date]
    diagnostics = []  # list of (label, error_text) for any query that failed

    compute_sql = """
        SELECT
            DATE_TRUNC('day', START_TIME) AS DATE,
            WAREHOUSE_NAME,
            SUM(CREDITS_USED) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
        WHERE START_TIME::DATE BETWEEN ? AND ?
        GROUP BY 1, 2
    """
    compute_df = cached_query(conn, compute_sql, params, cache_key=("compute", start_date, end_date))

    query_sql = """
        SELECT
            DATE_TRUNC('day', START_TIME) AS DATE,
            WAREHOUSE_NAME,
            USER_NAME,
            QUERY_TAG,
            ROLE_NAME,
            CREDITS_USED_CLOUD_SERVICES AS CREDITS_ATTRIBUTED
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE START_TIME::DATE BETWEEN ? AND ?
    """
    query_df = cached_query(conn, query_sql, params, cache_key=("query", start_date, end_date))

    cortex_df = load_cortex_usage(conn, start_date, end_date, diagnostics)

    storage_sql = """
        SELECT
            USAGE_DATE AS DATE,
            (STORAGE_BYTES + STAGE_BYTES) / POWER(1024, 4) AS ACTIVE_TB,
            FAILSAFE_BYTES / POWER(1024, 4) AS FAILSAFE_TB
        FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
        WHERE USAGE_DATE BETWEEN ? AND ?
    """
    storage_df = cached_query(conn, storage_sql, params, cache_key=("storage", start_date, end_date))
    if not storage_df.empty:
        storage_df["STORAGE_TB"] = storage_df["ACTIVE_TB"] + storage_df["FAILSAFE_TB"]

    repl_sql = """
        SELECT
            DATE_TRUNC('day', START_TIME) AS DATE,
            SUM(CREDITS_USED) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_USAGE_HISTORY
        WHERE START_TIME::DATE BETWEEN ? AND ?
        GROUP BY 1
    """
    repl_df = cached_query(conn, repl_sql, params, cache_key=("repl", start_date, end_date))

    egress_sql = """
        SELECT
            DATE_TRUNC('day', START_TIME) AS DATE,
            SUM(BYTES_TRANSFERRED) AS BYTES_TRANSFERRED
        FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
        WHERE START_TIME::DATE BETWEEN ? AND ?
          AND TRANSFER_TYPE = 'EXTERNAL'
        GROUP BY 1
    """
    egress_df = cached_query(conn, egress_sql, params, cache_key=("egress", start_date, end_date))

    service_type_sql = """
        SELECT
            DATE_TRUNC('day', USAGE_DATE) AS DATE,
            SERVICE_TYPE,
            SUM(CREDITS_USED) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
        WHERE USAGE_DATE BETWEEN ? AND ?
        GROUP BY 1, 2
    """
    try:
        service_type_df = cached_query(conn, service_type_sql, params, cache_key=("service_type", start_date, end_date))
    except Exception as e:
        diagnostics.append(("Compute by service type (METERING_DAILY_HISTORY)", str(e)))
        service_type_df = pd.DataFrame(columns=["DATE", "SERVICE_TYPE", "CREDITS"])

    return {
        "compute": compute_df,
        "query": query_df,
        "cortex": cortex_df,
        "storage": storage_df,
        "replication": repl_df,
        "egress": egress_df,
        "service_type": service_type_df,
        "_diagnostics": diagnostics,
    }


def load_cortex_usage(conn, start_date, end_date, diagnostics):
    """Pull Cortex AI credit usage from Snowflake's dedicated Account Usage
    views. Prefers the current, most granular views and falls back gracefully
    for accounts where a given view isn't available yet (e.g. older Snowflake
    releases, or before a view's GA date).

    Any query failure is appended to `diagnostics` as (label, error_text)
    instead of being silently swallowed, so the app can surface the real
    reason (permissions, missing view, bad SQL) instead of just showing
    "no data" with no explanation.

    Column names below are verified against Snowflake's Account Usage
    reference docs (each view has a genuinely different schema — they are
    NOT interchangeable):
      - CORTEX_AI_FUNCTIONS_USAGE_HISTORY: WAREHOUSE_ID, USER_ID, QUERY_TAG,
        ROLE_NAMES (an ARRAY — primary role is element [0]), FUNCTION_NAME,
        MODEL_NAME, CREDITS. Only includes usage on/after 2026-01-05; user/
        query tag/role attribution only populated for usage on/after
        2026-02-16 (earlier rows come back with those fields NULL).
      - CORTEX_ANALYST_USAGE_HISTORY: much sparser schema — just START_TIME,
        END_TIME, REQUEST_COUNT, CREDITS, USERNAME. No warehouse, query tag,
        or role at all.
      - CORTEX_AGENT_USAGE_HISTORY: USER_ID/USER_NAME at top level; role name
        is nested inside the METADATA object as METADATA:role_name. Credit
        figure is TOKEN_CREDITS (token-based agent costs only — this
        excludes METADATA:sql_query_credits, the warehouse compute an agent's
        SQL tool calls incurred, since that's warehouse cost already counted
        elsewhere, not Cortex-specific cost).
      - CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY: deprecated and no longer
        updated by Snowflake — used only as a last-resort fallback if
        CORTEX_AI_FUNCTIONS_USAGE_HISTORY isn't queryable at all (e.g. very
        old accounts), since it won't reflect current usage.
    """
    params = [start_date, end_date]
    frames = []

    ai_functions_sql = """
        SELECT
            DATE_TRUNC('day', START_TIME) AS DATE,
            WAREHOUSE_ID::STRING AS WAREHOUSE_NAME,
            USER_ID::STRING AS USER_NAME,
            QUERY_TAG,
            ROLE_NAMES[0]::STRING AS ROLE_NAME,
            FUNCTION_NAME,
            MODEL_NAME,
            SUM(CREDITS) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
        WHERE START_TIME::DATE BETWEEN ? AND ?
        GROUP BY 1, 2, 3, 4, 5, 6, 7
    """
    try:
        df = cached_query(conn, ai_functions_sql, params, cache_key=("cortex_ai_fn", start_date, end_date))
        df["SOURCE"] = "Cortex AI Functions"
        frames.append(df)
    except Exception as e:
        diagnostics.append(("Cortex AI Functions (CORTEX_AI_FUNCTIONS_USAGE_HISTORY)", str(e)))
        # Fall back to the deprecated view for older accounts — note this
        # view is no longer updated by Snowflake, so it won't show recent usage.
        try:
            legacy_sql = """
                SELECT
                    DATE_TRUNC('day', START_TIME) AS DATE,
                    WAREHOUSE_NAME,
                    NULL AS USER_NAME,
                    NULL AS QUERY_TAG,
                    NULL AS ROLE_NAME,
                    FUNCTION_NAME,
                    MODEL_NAME,
                    SUM(TOKENS) AS TOKENS,
                    SUM(CREDITS) AS CREDITS
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY
                WHERE START_TIME::DATE BETWEEN ? AND ?
                GROUP BY 1, 2, 3, 4, 5, 6, 7
            """
            df = cached_query(conn, legacy_sql, params, cache_key=("cortex_legacy", start_date, end_date))
            df["SOURCE"] = "Cortex Functions (legacy view)"
            frames.append(df)
        except Exception as e2:
            diagnostics.append(("Cortex Functions legacy fallback (CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY)", str(e2)))

    analyst_sql = """
        SELECT
            DATE_TRUNC('day', START_TIME) AS DATE,
            NULL AS WAREHOUSE_NAME,
            USERNAME AS USER_NAME,
            NULL AS QUERY_TAG,
            NULL AS ROLE_NAME,
            'CORTEX_ANALYST' AS FUNCTION_NAME,
            NULL AS MODEL_NAME,
            SUM(CREDITS) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
        WHERE START_TIME::DATE BETWEEN ? AND ?
        GROUP BY 1, 3
    """
    try:
        df = cached_query(conn, analyst_sql, params, cache_key=("cortex_analyst", start_date, end_date))
        df["SOURCE"] = "Cortex Analyst"
        frames.append(df)
    except Exception as e:
        diagnostics.append(("Cortex Analyst (CORTEX_ANALYST_USAGE_HISTORY)", str(e)))

    agent_sql = """
        SELECT
            DATE_TRUNC('day', START_TIME) AS DATE,
            METADATA:sql_query_warehouses[0]::STRING AS WAREHOUSE_NAME,
            USER_NAME,
            NULL AS QUERY_TAG,
            METADATA:role_name::STRING AS ROLE_NAME,
            'CORTEX_AGENT' AS FUNCTION_NAME,
            NULL AS MODEL_NAME,
            SUM(TOKEN_CREDITS) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
        WHERE START_TIME::DATE BETWEEN ? AND ?
        GROUP BY 1, 2, 3, 5
    """
    try:
        df = cached_query(conn, agent_sql, params, cache_key=("cortex_agent", start_date, end_date))
        df["SOURCE"] = "Cortex Agents"
        frames.append(df)
    except Exception as e:
        diagnostics.append(("Cortex Agents (CORTEX_AGENT_USAGE_HISTORY)", str(e)))

    # Cortex Code ("CoCo") — CLI, Snowsight, and Desktop each have their own
    # view with an identical schema. Role name is nested at METADATA:role_name;
    # there's no warehouse or query tag concept for these (interactive coding
    # assistant usage, not warehouse-run queries).
    coco_views = [
        ("CORTEX_CODE_CLI_USAGE_HISTORY", "Cortex Code (CLI)"),
        ("CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY", "Cortex Code (Snowsight)"),
        ("CORTEX_CODE_DESKTOP_USAGE_HISTORY", "Cortex Code (Desktop)"),
    ]
    for view_name, source_label in coco_views:
        coco_sql = f"""
            SELECT
                DATE_TRUNC('day', USAGE_TIME) AS DATE,
                NULL AS WAREHOUSE_NAME,
                USER_NAME,
                NULL AS QUERY_TAG,
                METADATA:role_name::STRING AS ROLE_NAME,
                '{source_label}' AS FUNCTION_NAME,
                NULL AS MODEL_NAME,
                SUM(TOKENS) AS TOKENS,
                SUM(TOKEN_CREDITS) AS CREDITS
            FROM SNOWFLAKE.ACCOUNT_USAGE.{view_name}
            WHERE USAGE_TIME::DATE BETWEEN ? AND ?
            GROUP BY 1, 2, 3, 5
        """
        try:
            df = cached_query(conn, coco_sql, params, cache_key=(view_name.lower(), start_date, end_date))
            df["SOURCE"] = source_label
            frames.append(df)
        except Exception as e:
            diagnostics.append((f"{source_label} ({view_name})", str(e)))

    if not frames:
        return pd.DataFrame(
            columns=["DATE", "WAREHOUSE_NAME", "USER_NAME", "QUERY_TAG", "ROLE_NAME",
                     "FUNCTION_NAME", "MODEL_NAME", "TOKENS", "CREDITS", "SOURCE"]
        )
    return pd.concat(frames, ignore_index=True)


# --------------------------------------------------------------------------
# Pricing assumptions (editable in sidebar) & derived cost calculations
# --------------------------------------------------------------------------
@dataclass
class PricingConfig:
    credit_price: float = 3.0          # $ per Snowflake credit
    storage_price_per_tb: float = 23.0  # $ per TB / month (approx on-demand)
    egress_price_per_gb: float = 0.09   # $ per GB transferred out


def build_category_costs(data, pricing: PricingConfig):
    """Roll up each raw dataset into a single tidy DataFrame:
    DATE, CATEGORY, CREDITS_OR_UNITS, COST_USD
    """
    frames = []

    # Compute
    compute = data["compute"].copy()
    if not compute.empty:
        daily = compute.groupby("DATE", as_index=False)["CREDITS"].sum()
        daily["CATEGORY"] = "Compute"
        daily["COST_USD"] = daily["CREDITS"] * pricing.credit_price
        frames.append(daily[["DATE", "CATEGORY", "CREDITS", "COST_USD"]].rename(columns={"CREDITS": "UNITS"}))

    # AI services (from dedicated CORTEX_*_USAGE_HISTORY views)
    cortex = data.get("cortex", pd.DataFrame()).copy()
    if not cortex.empty and "CREDITS" in cortex.columns:
        daily = cortex.groupby("DATE", as_index=False)["CREDITS"].sum()
        daily["CATEGORY"] = "AI Services"
        daily["COST_USD"] = daily["CREDITS"] * pricing.credit_price
        frames.append(daily.rename(columns={"CREDITS": "UNITS"})[["DATE", "CATEGORY", "UNITS", "COST_USD"]])

    # Storage
    storage = data["storage"].copy()
    if not storage.empty:
        daily = storage.groupby("DATE", as_index=False)["STORAGE_TB"].mean()
        daily["CATEGORY"] = "Storage"
        # Approximate a daily cost by spreading the monthly $/TB rate over ~30 days
        daily["COST_USD"] = daily["STORAGE_TB"] * (pricing.storage_price_per_tb / 30.0)
        frames.append(daily.rename(columns={"STORAGE_TB": "UNITS"})[["DATE", "CATEGORY", "UNITS", "COST_USD"]])

    # Replication
    repl = data["replication"].copy()
    if not repl.empty:
        daily = repl.groupby("DATE", as_index=False)["CREDITS"].sum()
        daily["CATEGORY"] = "Replication"
        daily["COST_USD"] = daily["CREDITS"] * pricing.credit_price
        frames.append(daily.rename(columns={"CREDITS": "UNITS"})[["DATE", "CATEGORY", "UNITS", "COST_USD"]])

    # Egress
    egress = data["egress"].copy()
    if not egress.empty:
        daily = egress.groupby("DATE", as_index=False)["BYTES_TRANSFERRED"].sum()
        daily["UNITS"] = daily["BYTES_TRANSFERRED"] / 1e9  # GB
        daily["CATEGORY"] = "Egress"
        daily["COST_USD"] = daily["UNITS"] * pricing.egress_price_per_gb
        frames.append(daily[["DATE", "CATEGORY", "UNITS", "COST_USD"]])

    # Other serverless (from METERING_DAILY_HISTORY, SERVICE_TYPE breakdown).
    # This is the only place that captures Automatic Clustering, Search
    # Optimization, Materialized View maintenance, Query Acceleration,
    # Snowpipe, and any other serverless feature Snowflake meters — none of
    # which appear in WAREHOUSE_METERING_HISTORY at all. Excludes service
    # types already counted via a more specific source above, to avoid
    # double-counting: WAREHOUSE_METERING (-> Compute), REPLICATION
    # (-> Replication), and AI_SERVICES/CORTEX_CODE_* (-> AI Services, via
    # the dedicated Cortex views).
    ALREADY_COUNTED_SERVICE_TYPES = {
        "WAREHOUSE_METERING",
        "WAREHOUSE_METERING_READER",
        "REPLICATION",
        "AI_SERVICES",
        "CORTEX_CODE_CLI",
        "CORTEX_CODE_SNOWSIGHT",
        "CORTEX_CODE_DESKTOP",
    }
    service_type = data.get("service_type", pd.DataFrame()).copy()
    if not service_type.empty:
        other = service_type[~service_type["SERVICE_TYPE"].isin(ALREADY_COUNTED_SERVICE_TYPES)]
        if not other.empty:
            daily = other.groupby("DATE", as_index=False)["CREDITS"].sum()
            daily["CATEGORY"] = "Other Serverless"
            daily["COST_USD"] = daily["CREDITS"] * pricing.credit_price
            frames.append(daily.rename(columns={"CREDITS": "UNITS"})[["DATE", "CATEGORY", "UNITS", "COST_USD"]])

    if not frames:
        return pd.DataFrame(columns=["DATE", "CATEGORY", "UNITS", "COST_USD"])

    out = pd.concat(frames, ignore_index=True)
    out["DATE"] = pd.to_datetime(out["DATE"])
    return out


def apply_filters(query_df, warehouses, tags, users, roles):
    df = query_df.copy()
    if warehouses:
        df = df[df["WAREHOUSE_NAME"].isin(warehouses)]
    if tags:
        df = df[df["QUERY_TAG"].isin(tags)]
    if users:
        df = df[df["USER_NAME"].isin(users)]
    if roles:
        df = df[df["ROLE_NAME"].isin(roles)]
    return df


def rollup_role_to_department(role_series, delimiter):
    if not delimiter:
        return role_series
    return role_series.astype(str).apply(
        lambda r: r.split(delimiter)[0] if delimiter in r else r
    )


def apply_cortex_filters(cortex_df, warehouses, tags, users, roles):
    """Same idea as apply_filters, but leaves rows with NULL attribution
    (pre-2026-02-16 Cortex usage) untouched by the user/tag/role filters
    unless the person has actively selected values that would exclude them —
    those unattributed rows simply won't match a specific selection, which is
    the correct/expected behavior."""
    df = cortex_df.copy()
    if warehouses and "WAREHOUSE_NAME" in df.columns:
        df = df[df["WAREHOUSE_NAME"].isin(warehouses)]
    if tags and "QUERY_TAG" in df.columns:
        df = df[df["QUERY_TAG"].isin(tags)]
    if users and "USER_NAME" in df.columns:
        df = df[df["USER_NAME"].isin(users)]
    if roles and "ROLE_NAME" in df.columns:
        df = df[df["ROLE_NAME"].isin(roles)]
    return df


# --------------------------------------------------------------------------
# Sidebar: connection
# --------------------------------------------------------------------------
st.sidebar.title("❄️ Snowflake Cost Explorer")

_session, is_sis = get_session()

with st.sidebar.expander(
    "🔌 Connection",
    expanded=not is_sis and "sf_session" not in st.session_state,
):
    if is_sis:
        st.success("Running inside Snowflake — using this app's session automatically.")
        demo_mode = st.checkbox("Use demo data instead", value=False)
    else:
        demo_mode = st.checkbox("Use demo data (no connection)", value=True)

        if not demo_mode:
            account = st.text_input("Account identifier", placeholder="xy12345.us-east-1")
            user = st.text_input("Username")
            authenticator = st.radio("Auth method", ["Password", "SSO / External Browser"], horizontal=True)
            password = st.text_input("Password", type="password") if authenticator == "Password" else None
            role = st.text_input("Role", value="ACCOUNTADMIN")
            warehouse = st.text_input("Warehouse (for running these queries)", value="COMPUTE_WH")

            if st.button("Connect", use_container_width=True):
                try:
                    with st.spinner("Connecting to Snowflake..."):
                        new_session = try_connect(account, user, password, role, warehouse, authenticator)
                    st.session_state["sf_session"] = new_session
                    st.success("Connected.")
                except Exception as e:
                    st.error(f"Connection failed: {e}")

            if st.session_state.get("sf_session"):
                if st.button("Disconnect", use_container_width=True):
                    try:
                        st.session_state["sf_session"].close()
                    except Exception:
                        pass
                    del st.session_state["sf_session"]
                    st.rerun()

with st.sidebar.expander("💲 Pricing assumptions"):
    credit_price = st.number_input("$ per credit", min_value=0.0, value=3.00, step=0.05)
    storage_price = st.number_input("$ per TB / month (storage)", min_value=0.0, value=23.00, step=0.5)
    egress_price = st.number_input("$ per GB (egress)", min_value=0.0, value=0.09, step=0.01)

pricing = PricingConfig(credit_price=credit_price, storage_price_per_tb=storage_price, egress_price_per_gb=egress_price)

# --------------------------------------------------------------------------
# Sidebar: date range
# --------------------------------------------------------------------------
st.sidebar.markdown("---")
today = dt.date.today()
first_of_month = today.replace(day=1)

DATE_PRESETS = {
    "Month to date": (first_of_month, today),
    "Last 30 days": (today - dt.timedelta(days=30), today),
    "Last 90 days": (today - dt.timedelta(days=90), today),
    "Last 365 days (max ACCOUNT_USAGE history)": (today - dt.timedelta(days=365), today),
    "Custom range": None,
}
preset_label = st.sidebar.selectbox(
    "Date range preset",
    list(DATE_PRESETS.keys()),
    help="ACCOUNT_USAGE views only retain ~365 days of history, so \"Last 365 days\" is "
    "as close to full account lifetime as this app can show. Useful for reconciling "
    "against Snowsight's lifetime/trial usage totals, which aren't limited to 365 days.",
)

if DATE_PRESETS[preset_label] is not None:
    start_date, end_date = DATE_PRESETS[preset_label]
    st.sidebar.caption(f"{start_date:%b %d, %Y} – {end_date:%b %d, %Y}")
else:
    date_range = st.sidebar.date_input(
        "Custom date range",
        value=(first_of_month, today),
        max_value=today,
    )
    if isinstance(date_range, tuple) and len(date_range) == 2:
        start_date, end_date = date_range
    else:
        start_date, end_date = first_of_month, today

# --------------------------------------------------------------------------
# Load data
# --------------------------------------------------------------------------
conn, _ = get_session()

if demo_mode or conn is None:
    if not demo_mode and conn is None:
        st.sidebar.warning("Not connected — showing demo data.")
    raw_data = generate_mock_data(start_date, end_date)
else:
    try:
        raw_data = load_live_data(conn, start_date, end_date)
    except Exception as e:
        st.sidebar.error(f"Query failed, falling back to demo data: {e}")
        raw_data = generate_mock_data(start_date, end_date)

_diagnostics = raw_data.get("_diagnostics", [])
if _diagnostics:
    with st.expander(f"⚠️ {len(_diagnostics)} data source issue(s) — click for details", expanded=True):
        st.caption(
            "The sections below are showing partial or no data for these sources. "
            "Common causes: the running role lacks SELECT on the view (grant "
            "`IMPORTED PRIVILEGES` on the `SNOWFLAKE` database, or a more specific "
            "grant on the view itself), the view doesn't exist yet on this Snowflake "
            "release/region, or there's a genuine SQL error below."
        )
        for label, error_text in _diagnostics:
            st.markdown(f"**{label}**")
            st.code(error_text, language=None)

query_df = raw_data["query"]

# --------------------------------------------------------------------------
# Sidebar: dimension filters (populated dynamically from data)
# --------------------------------------------------------------------------
st.sidebar.markdown("---")
st.sidebar.subheader("Filters")

warehouse_opts = sorted(query_df["WAREHOUSE_NAME"].dropna().unique().tolist()) if not query_df.empty else []
tag_opts = sorted([t for t in query_df["QUERY_TAG"].dropna().unique().tolist()]) if not query_df.empty else []
user_opts = sorted(query_df["USER_NAME"].dropna().unique().tolist()) if not query_df.empty else []
role_opts = sorted(query_df["ROLE_NAME"].dropna().unique().tolist()) if not query_df.empty else []

sel_warehouses = st.sidebar.multiselect("Warehouse", warehouse_opts)
sel_tags = st.sidebar.multiselect("Query tag", tag_opts)
sel_users = st.sidebar.multiselect("User", user_opts)
sel_roles = st.sidebar.multiselect("Role", role_opts)

with st.sidebar.expander("🏢 Department rollup (optional)"):
    st.caption("If roles follow a naming convention like DEPT_ANALYST, split on a delimiter to roll up to department level.")
    dept_delimiter = st.text_input("Delimiter", value="_", max_chars=3)
    use_dept_rollup = st.checkbox("Enable department rollup", value=False)

filtered_query_df = apply_filters(query_df, sel_warehouses, sel_tags, sel_users, sel_roles)

cortex_df = raw_data.get("cortex", pd.DataFrame())
filtered_cortex_df = apply_cortex_filters(cortex_df, sel_warehouses, sel_tags, sel_users, sel_roles)

# --------------------------------------------------------------------------
# Header / KPIs
# --------------------------------------------------------------------------
st.title("Snowflake Cost Breakdown")
st.caption(f"{start_date:%b %d, %Y} – {end_date:%b %d, %Y}")

cost_df = build_category_costs(raw_data, pricing)

total_cost = cost_df["COST_USD"].sum() if not cost_df.empty else 0.0
total_credits = cost_df.loc[cost_df["CATEGORY"].isin(["Compute", "AI Services", "Replication"]), "UNITS"].sum() if not cost_df.empty else 0.0

if not cost_df.empty:
    by_cat = cost_df.groupby("CATEGORY", as_index=False)["COST_USD"].sum().sort_values("COST_USD", ascending=False)
    top_category = by_cat.iloc[0]["CATEGORY"] if not by_cat.empty else "—"
    top_category_cost = by_cat.iloc[0]["COST_USD"] if not by_cat.empty else 0.0
else:
    top_category, top_category_cost = "—", 0.0

# Rough month-over-month comparison (previous period of equal length)
period_len = (end_date - start_date).days + 1
prev_start = start_date - dt.timedelta(days=period_len)
prev_end = start_date - dt.timedelta(days=1)
if demo_mode or conn is None:
    prev_raw = generate_mock_data(prev_start, prev_end, seed=7)
else:
    try:
        prev_raw = load_live_data(conn, prev_start, prev_end)
    except Exception:
        prev_raw = generate_mock_data(prev_start, prev_end, seed=7)
prev_cost_df = build_category_costs(prev_raw, pricing)
prev_total = prev_cost_df["COST_USD"].sum() if not prev_cost_df.empty else 0.0
mom_pct = ((total_cost - prev_total) / prev_total * 100) if prev_total else 0.0

k1, k2, k3, k4 = st.columns(4)
k1.metric("Total estimated cost", f"${total_cost:,.0f}")
k2.metric("Vs. prior period", f"{mom_pct:+.1f}%")
k3.metric("Top cost driver", top_category, f"${top_category_cost:,.0f}")
k4.metric("Compute + AI + Repl. credits", f"{total_credits:,.1f}")

st.markdown("---")

# --------------------------------------------------------------------------
# Category breakdown charts
# --------------------------------------------------------------------------
c1, c2 = st.columns([1, 1.4])

with c1:
    st.subheader("Cost by category")
    if not cost_df.empty:
        pie_df = cost_df.groupby("CATEGORY", as_index=False)["COST_USD"].sum()
        fig = px.pie(
            pie_df,
            names="CATEGORY",
            values="COST_USD",
            color="CATEGORY",
            color_discrete_map=CATEGORY_COLORS,
            hole=0.45,
        )
        fig.update_traces(textinfo="percent+label")
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("No data for the selected period.")

with c2:
    st.subheader("Daily cost trend by category")
    if not cost_df.empty:
        trend = cost_df.groupby(["DATE", "CATEGORY"], as_index=False)["COST_USD"].sum()
        fig = px.bar(
            trend,
            x="DATE",
            y="COST_USD",
            color="CATEGORY",
            color_discrete_map=CATEGORY_COLORS,
            category_orders={"CATEGORY": CATEGORY_ORDER},
        )
        fig.update_layout(barmode="stack", xaxis_title=None, yaxis_title="Cost (USD)")
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("No data for the selected period.")

st.markdown("---")

# --------------------------------------------------------------------------
# Compute breakdown by service type (METERING_DAILY_HISTORY)
# --------------------------------------------------------------------------
st.subheader("⚙️ Compute breakdown by service type")

show_service_breakdown = st.checkbox(
    "Break down compute by service type",
    value=False,
    help="Sources SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY — includes warehouse "
    "compute plus serverless features like Automatic Clustering, Search Optimization, "
    "Materialized View maintenance, Query Acceleration, Snowpipe, and Cortex Code (CoCo). "
    "This view reports account-wide totals per service type — it can't be filtered by "
    "warehouse, user, tag, or role.",
)

if show_service_breakdown:
    service_df = raw_data.get("service_type", pd.DataFrame()).copy()

    if service_df.empty:
        st.info("No service-type usage data available for this period/account.")
    else:
        type_opts = sorted(service_df["SERVICE_TYPE"].dropna().unique().tolist())
        selected_types = st.multiselect("Service types to include", type_opts, default=type_opts)
        service_df = service_df[service_df["SERVICE_TYPE"].isin(selected_types)]

        if service_df.empty:
            st.info("No data for the selected service types.")
        else:
            service_df["COST_USD"] = service_df["CREDITS"] * pricing.credit_price

            s1, s2 = st.columns([1, 1.4])
            with s1:
                pie_df = service_df.groupby("SERVICE_TYPE", as_index=False)["COST_USD"].sum()
                fig = px.pie(pie_df, names="SERVICE_TYPE", values="COST_USD", hole=0.45)
                fig.update_traces(textinfo="percent+label")
                st.plotly_chart(fig, use_container_width=True)
            with s2:
                trend = service_df.groupby(["DATE", "SERVICE_TYPE"], as_index=False)["COST_USD"].sum()
                fig = px.bar(trend, x="DATE", y="COST_USD", color="SERVICE_TYPE")
                fig.update_layout(barmode="stack", xaxis_title=None, yaxis_title="Cost (USD)")
                st.plotly_chart(fig, use_container_width=True)

            table = (
                service_df.groupby("SERVICE_TYPE", as_index=False)
                .agg(CREDITS=("CREDITS", "sum"), COST_USD=("COST_USD", "sum"))
                .sort_values("COST_USD", ascending=False)
            )
            st.dataframe(
                table.rename(columns={"SERVICE_TYPE": "Service Type", "CREDITS": "Credits", "COST_USD": "Est. Cost ($)"}),
                use_container_width=True,
                hide_index=True,
            )

            st.caption(
                "WAREHOUSE_METERING here reflects the same warehouse credits shown in the "
                "\"Compute\" category above. The other service types shown here (clustering, "
                "search optimization, Snowpipe, Cortex Code, etc.) are counted in the "
                "top-level total under a separate \"Other Serverless\" category — this view "
                "just lets you see that composition in detail."
            )

st.markdown("---")

# --------------------------------------------------------------------------
# Storage breakdown: regular vs Fail-safe
# --------------------------------------------------------------------------
st.subheader("🗄️ Storage breakdown — regular vs Fail-safe")

show_storage_breakdown = st.checkbox(
    "Break down storage by regular vs Fail-safe",
    value=False,
    help="Sources SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE — splits billable storage into "
    "regular (active table + stage bytes) and Fail-safe (recently deleted data still "
    "billed during the account's Fail-safe retention window). Both are billed at the "
    "same per-TB storage rate.",
)

if show_storage_breakdown:
    storage_bd_df = raw_data.get("storage", pd.DataFrame()).copy()

    if storage_bd_df.empty or "ACTIVE_TB" not in storage_bd_df.columns:
        st.info("No storage breakdown data available for this period/account.")
    else:
        melted = storage_bd_df.melt(
            id_vars=["DATE"],
            value_vars=["ACTIVE_TB", "FAILSAFE_TB"],
            var_name="STORAGE_TYPE",
            value_name="TB",
        )
        melted["STORAGE_TYPE"] = melted["STORAGE_TYPE"].map(
            {"ACTIVE_TB": "Regular", "FAILSAFE_TB": "Fail-safe"}
        )
        melted["COST_USD"] = melted["TB"] * (pricing.storage_price_per_tb / 30.0)

        t1, t2 = st.columns([1, 1.4])
        with t1:
            pie_df = melted.groupby("STORAGE_TYPE", as_index=False)["COST_USD"].sum()
            fig = px.pie(pie_df, names="STORAGE_TYPE", values="COST_USD", hole=0.45)
            fig.update_traces(textinfo="percent+label")
            st.plotly_chart(fig, use_container_width=True)
        with t2:
            fig = px.bar(melted, x="DATE", y="TB", color="STORAGE_TYPE")
            fig.update_layout(barmode="stack", xaxis_title=None, yaxis_title="Storage (TB)")
            st.plotly_chart(fig, use_container_width=True)

        table = (
            melted.groupby("STORAGE_TYPE", as_index=False)
            .agg(AVG_TB=("TB", "mean"), COST_USD=("COST_USD", "sum"))
            .sort_values("COST_USD", ascending=False)
        )
        st.dataframe(
            table.rename(columns={"STORAGE_TYPE": "Storage Type", "AVG_TB": "Avg. TB/day", "COST_USD": "Est. Cost ($)"}),
            use_container_width=True,
            hide_index=True,
        )

        st.caption(
            "Regular and Fail-safe storage are billed at the same per-TB rate — this view "
            "just separates how much of your storage bill is recently deleted data still "
            "being retained (Fail-safe, typically a 7-day window after Time Travel expires) "
            "versus active data and stage files."
        )

st.markdown("---")

# --------------------------------------------------------------------------
# Cost deep-dive: selectable dimension (Warehouse / User / Query Tag / Role)
# --------------------------------------------------------------------------
st.subheader("🔎 Cost deep-dive")

DIMENSION_OPTIONS = {
    "Warehouse": "WAREHOUSE_NAME",
    "User": "USER_NAME",
    "Query Tag": "QUERY_TAG",
    "Role": "ROLE_NAME",
}
selected_label = st.radio(
    "View cost breakdown by:",
    list(DIMENSION_OPTIONS.keys()),
    horizontal=True,
)
dim_col = DIMENSION_OPTIONS[selected_label]

frames = []

# Compute (real warehouse credits from WAREHOUSE_METERING_HISTORY) — only
# attributable at the warehouse level; Snowflake doesn't expose per-query
# warehouse credit consumption.
if dim_col == "WAREHOUSE_NAME":
    wdf = raw_data["compute"].copy()
    if sel_warehouses:
        wdf = wdf[wdf["WAREHOUSE_NAME"].isin(sel_warehouses)]
    if not wdf.empty:
        g = wdf.groupby("WAREHOUSE_NAME", as_index=False)["CREDITS"].sum()
        g = g.rename(columns={"WAREHOUSE_NAME": "DIM_VALUE"})
        g["SOURCE"] = "Compute"
        frames.append(g)

# Cloud services credits (from QUERY_HISTORY) — available for all four dimensions.
qdf = filtered_query_df.copy()
if not qdf.empty and dim_col in qdf.columns:
    if dim_col == "QUERY_TAG":
        qdf["QUERY_TAG"] = qdf["QUERY_TAG"].fillna("(untagged)")
    elif dim_col == "ROLE_NAME":
        qdf["ROLE_NAME"] = qdf["ROLE_NAME"].fillna("(no role)")
        if use_dept_rollup:
            qdf["ROLE_NAME"] = rollup_role_to_department(qdf["ROLE_NAME"], dept_delimiter)
    g = (
        qdf.groupby(dim_col, as_index=False)["CREDITS_ATTRIBUTED"]
        .sum()
        .rename(columns={dim_col: "DIM_VALUE", "CREDITS_ATTRIBUTED": "CREDITS"})
    )
    g["SOURCE"] = "Cloud Services"
    frames.append(g)

# AI (Cortex) credits — available for all four dimensions, subject to the
# Feb 16 2026 attribution cutoff on user/tag/role (see AI deep-dive below).
adf = filtered_cortex_df.copy()
if not adf.empty and dim_col in adf.columns:
    if dim_col == "QUERY_TAG":
        adf["QUERY_TAG"] = adf["QUERY_TAG"].fillna("(untagged)")
    elif dim_col == "ROLE_NAME":
        adf["ROLE_NAME"] = adf["ROLE_NAME"].fillna("(no role)")
        if use_dept_rollup:
            adf["ROLE_NAME"] = rollup_role_to_department(adf["ROLE_NAME"], dept_delimiter)
    elif dim_col == "USER_NAME":
        adf["USER_NAME"] = adf["USER_NAME"].fillna("(unattributed)")
    g = adf.groupby(dim_col, as_index=False)["CREDITS"].sum().rename(columns={dim_col: "DIM_VALUE"})
    g["SOURCE"] = "AI Services"
    frames.append(g)

if frames:
    combined = pd.concat(frames, ignore_index=True)
    combined["COST_USD"] = combined["CREDITS"] * pricing.credit_price

    totals = combined.groupby("DIM_VALUE", as_index=False)["COST_USD"].sum().sort_values("COST_USD", ascending=False)
    top_values = totals["DIM_VALUE"].head(20).tolist()
    plot_df = combined[combined["DIM_VALUE"].isin(top_values)]

    d1, d2 = st.columns([1.4, 1])
    with d1:
        fig = px.bar(
            plot_df,
            x="DIM_VALUE",
            y="COST_USD",
            color="SOURCE",
            category_orders={"DIM_VALUE": top_values},
        )
        fig.update_layout(barmode="stack", xaxis_title=None, yaxis_title="Est. cost (USD)")
        st.plotly_chart(fig, use_container_width=True)
    with d2:
        table = (
            combined.groupby("DIM_VALUE", as_index=False)
            .agg(CREDITS=("CREDITS", "sum"), COST_USD=("COST_USD", "sum"))
            .sort_values("COST_USD", ascending=False)
        )
        st.dataframe(
            table.rename(columns={"DIM_VALUE": selected_label, "CREDITS": "Credits", "COST_USD": "Est. Cost ($)"}),
            use_container_width=True,
            hide_index=True,
        )

    if dim_col != "WAREHOUSE_NAME":
        st.caption(
            "Compute credits aren't attributable at the per-query level in Snowflake's schema, "
            f"so this view shows Cloud Services + AI Services credits by {selected_label.lower()}. "
            "Select \"Warehouse\" to see full compute costs included."
        )
    if dim_col == "ROLE_NAME" and use_dept_rollup:
        st.caption(
            f"Rollup rule: role name split on '{dept_delimiter}', first segment used as department. "
            "Adjust the delimiter in the sidebar if your naming convention differs."
        )
else:
    st.info("No data available for this breakdown with the current filters.")

st.markdown("---")

# --------------------------------------------------------------------------
# AI Services deep-dive (Cortex)
# --------------------------------------------------------------------------
st.subheader("🤖 AI services deep-dive — Cortex")
if not filtered_cortex_df.empty:
    unattributed_share = filtered_cortex_df["USER_NAME"].isna().mean() if "USER_NAME" in filtered_cortex_df else 0
    if unattributed_share > 0:
        st.caption(
            f"{unattributed_share:.0%} of Cortex usage in this range has no user/tag/role attribution "
            "(Snowflake only began populating those fields for usage on/after Feb 16, 2026)."
        )

    a1, a2, a3 = st.columns(3)

    with a1:
        st.markdown("**By function**")
        fn_summary = (
            filtered_cortex_df.groupby("FUNCTION_NAME", as_index=False)["CREDITS"]
            .sum()
            .sort_values("CREDITS", ascending=False)
        )
        fig = px.bar(fn_summary, x="FUNCTION_NAME", y="CREDITS")
        fig.update_layout(xaxis_title=None, yaxis_title="Credits")
        st.plotly_chart(fig, use_container_width=True)

    with a2:
        st.markdown("**By model**")
        if "MODEL_NAME" in filtered_cortex_df.columns and filtered_cortex_df["MODEL_NAME"].notna().any():
            model_df = filtered_cortex_df.copy()
            model_df["MODEL_NAME"] = model_df["MODEL_NAME"].fillna("(n/a)")
            model_summary = (
                model_df.groupby("MODEL_NAME", as_index=False)["CREDITS"]
                .sum()
                .sort_values("CREDITS", ascending=False)
            )
            fig = px.bar(model_summary, x="MODEL_NAME", y="CREDITS")
            fig.update_layout(xaxis_title=None, yaxis_title="Credits")
            st.plotly_chart(fig, use_container_width=True)
        else:
            st.info("No model-level data available.")

    with a3:
        st.markdown("**By source**")
        if "SOURCE" in filtered_cortex_df.columns:
            source_summary = (
                filtered_cortex_df.groupby("SOURCE", as_index=False)["CREDITS"]
                .sum()
                .sort_values("CREDITS", ascending=False)
            )
            fig = px.pie(source_summary, names="SOURCE", values="CREDITS", hole=0.45)
            st.plotly_chart(fig, use_container_width=True)
        else:
            st.info("No source breakdown available.")

    attributed = filtered_cortex_df.dropna(subset=["USER_NAME"]) if "USER_NAME" in filtered_cortex_df else pd.DataFrame()
    if not attributed.empty:
        au1, au2 = st.columns(2)
        with au1:
            st.markdown("**By user (attributed usage only)**")
            user_ai = (
                attributed.groupby("USER_NAME", as_index=False)["CREDITS"]
                .sum()
                .sort_values("CREDITS", ascending=False)
                .head(15)
            )
            fig = px.bar(user_ai, x="USER_NAME", y="CREDITS")
            fig.update_layout(xaxis_title=None, yaxis_title="Credits")
            st.plotly_chart(fig, use_container_width=True)
        with au2:
            st.markdown("**By role (attributed usage only)**")
            role_ai_df = attributed.copy()
            role_ai_df["ROLE_NAME"] = role_ai_df["ROLE_NAME"].fillna("(no role)")
            if use_dept_rollup:
                role_ai_df["DEPARTMENT"] = rollup_role_to_department(role_ai_df["ROLE_NAME"], dept_delimiter)
                group_col, label = "DEPARTMENT", "department"
            else:
                group_col, label = "ROLE_NAME", "role"
            role_ai = (
                role_ai_df.groupby(group_col, as_index=False)["CREDITS"]
                .sum()
                .sort_values("CREDITS", ascending=False)
            )
            fig = px.bar(role_ai, x=group_col, y="CREDITS")
            fig.update_layout(xaxis_title=None, yaxis_title="Credits")
            st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("No attributed (user/role) Cortex usage in this range yet — showing function/model/source views only.")
else:
    st.info("No Cortex AI usage data for the selected period/filters.")

st.markdown("---")

# --------------------------------------------------------------------------
# Raw data table + export
# --------------------------------------------------------------------------
st.subheader("📄 Detail & export")
tab1, tab2, tab3 = st.tabs(["Category cost detail", "Query-level detail", "Cortex AI detail"])

with tab1:
    if not cost_df.empty:
        display_df = cost_df.sort_values(["DATE", "CATEGORY"])
        st.dataframe(display_df, use_container_width=True, hide_index=True)
        st.download_button(
            "Download category cost CSV",
            display_df.to_csv(index=False).encode("utf-8"),
            file_name=f"snowflake_cost_by_category_{start_date}_{end_date}.csv",
            mime="text/csv",
        )
    else:
        st.info("No data to display.")

with tab2:
    if not filtered_query_df.empty:
        st.dataframe(filtered_query_df, use_container_width=True, hide_index=True)
        st.download_button(
            "Download query-level CSV",
            filtered_query_df.to_csv(index=False).encode("utf-8"),
            file_name=f"snowflake_query_detail_{start_date}_{end_date}.csv",
            mime="text/csv",
        )
    else:
        st.info("No data to display.")

with tab3:
    if not filtered_cortex_df.empty:
        st.dataframe(filtered_cortex_df, use_container_width=True, hide_index=True)
        st.download_button(
            "Download Cortex AI usage CSV",
            filtered_cortex_df.to_csv(index=False).encode("utf-8"),
            file_name=f"snowflake_cortex_usage_{start_date}_{end_date}.csv",
            mime="text/csv",
        )
    else:
        st.info("No data to display.")

st.markdown("---")
st.caption(
    "Cost figures are estimates based on the pricing assumptions in the sidebar and standard "
    "ACCOUNT_USAGE views. Actual billing may differ — reconcile against your Snowflake invoice "
    "for exact figures."
)
