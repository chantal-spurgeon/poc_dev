"""
Databricks Cost Explorer
------------------------
A Streamlit app for monitoring and breaking down Databricks costs by
category (All-Purpose Compute, Jobs Compute, SQL Warehouses, DLT/Lakeflow,
Model Serving/AI, Vector Search), with drill-downs by cluster, warehouse,
user, tag, and workspace.

Data source: the `system` schema (System Tables), specifically:
  - system.billing.usage — the core usage log (DBUs consumed per record)
  - system.billing.list_prices — historical $/DBU by SKU (Type-2 SCD)
  - system.compute.clusters — cluster_id -> cluster_name lookup
  - system.compute.warehouses — warehouse_id -> warehouse_name lookup

Unlike Snowflake, Databricks does NOT bill for storage directly — your data
sits in your own cloud storage (S3/ADLS/GCS), billed by the cloud provider,
not Databricks. So there's no "Storage" category here by design, not by
omission. Likewise there's no single flat "$ per credit" — each SKU has its
own $/DBU rate from list_prices, which this app joins against usage rather
than using one fixed price assumption.

This app is designed to run in EITHER of two modes, auto-detected at startup:
  1. Databricks Apps — deployed natively in a Databricks workspace. Auth is
     handled automatically via the platform's injected OAuth credentials; no
     login form needed. See README.md for deployment steps.
  2. Standalone / local — run with `streamlit run app.py` outside Databricks.
     Uses a login form in the sidebar (host + HTTP path + personal access
     token), or demo data with no connection at all.

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
    page_title="Databricks Cost Explorer",
    page_icon="🧱",
    layout="wide",
)

CATEGORY_COLORS = {
    "All-Purpose Compute": "#FF3621",
    "Jobs Compute": "#FF8C61",
    "SQL Warehouses": "#00A972",
    "DLT / Lakeflow": "#1B3139",
    "Model Serving / AI": "#7D44CF",
    "Vector Search": "#8A8F98",
    "Other": "#B7BDC6",
}
CATEGORY_ORDER = list(CATEGORY_COLORS.keys())

# Category classification is done by matching keywords in sku_name, since
# there's no single fully-documented enum of billing_origin_product values
# to rely on, and sku_name follows well-documented, stable naming
# conventions (e.g. STANDARD_ALL_PURPOSE_COMPUTE, ENTERPRISE_JOBS_COMPUTE,
# SERVERLESS_REAL_TIME_INFERENCE, etc). This is a heuristic, not an exact
# Databricks-provided taxonomy — sku_name is always shown alongside category
# in the detail views so you can verify or adjust it.
SKU_CATEGORY_RULES = [
    ("Vector Search", ["VECTOR_SEARCH"]),
    ("Model Serving / AI", ["MODEL_SERVING", "SERVING", "INFERENCE", "FOUNDATION_MODEL", "AI_"]),
    ("DLT / Lakeflow", ["DLT", "LAKEFLOW", "PIPELINE"]),
    ("SQL Warehouses", ["SQL"]),
    ("Jobs Compute", ["JOBS_COMPUTE", "JOBS_LIGHT", "_JOBS_"]),
    ("All-Purpose Compute", ["ALL_PURPOSE"]),
]


def classify_sku(sku_name):
    if not sku_name:
        return "Other"
    upper = sku_name.upper()
    for category, keywords in SKU_CATEGORY_RULES:
        if any(kw in upper for kw in keywords):
            return category
    return "Other"


# --------------------------------------------------------------------------
# Connection handling
#
# Supports two run modes:
#  - Databricks Apps: auth is injected automatically by the platform via
#    OAuth (no login needed) — detected via the presence of DATABRICKS_HOST
#    in the environment combined with a working default credential chain.
#  - Standalone: a connection is built from sidebar-entered host/HTTP
#    path/token and cached in st.session_state.
# --------------------------------------------------------------------------
@st.cache_resource(show_spinner=False)
def get_apps_connection():
    """Return a databricks-sql connection using the platform's injected
    OAuth credentials if running inside Databricks Apps, else None."""
    import os

    host = os.environ.get("DATABRICKS_HOST")
    warehouse_http_path = os.environ.get("DATABRICKS_WAREHOUSE_HTTP_PATH") or os.environ.get("DATABRICKS_HTTP_PATH")
    if not host or not warehouse_http_path:
        return None
    try:
        from databricks import sql
        from databricks.sdk.core import Config

        return sql.connect(
            server_hostname=host.replace("https://", "").replace("http://", ""),
            http_path=warehouse_http_path,
            credentials_provider=lambda: Config().authenticate,
        )
    except Exception:
        return None


def get_connection():
    """Return (connection, is_apps) — the connection to use, and whether it
    came from running natively inside Databricks Apps."""
    apps_conn = get_apps_connection()
    if apps_conn is not None:
        return apps_conn, True
    return st.session_state.get("db_conn"), False


def try_connect(host, http_path, token):
    from databricks import sql

    return sql.connect(
        server_hostname=host.replace("https://", "").replace("http://", ""),
        http_path=http_path,
        access_token=token,
    )


def run_query(conn, sql_text, params=None):
    """Run a query and return a pandas DataFrame. Uses the connector's
    current `:name` named-parameter style (the legacy %(name)s pyformat
    style is being deprecated)."""
    cur = conn.cursor()
    try:
        if params:
            cur.execute(sql_text, parameters=params)
        else:
            cur.execute(sql_text)
        cols = [c[0] for c in cur.description]
        rows = cur.fetchall()
        return pd.DataFrame(rows, columns=cols)
    finally:
        cur.close()


@st.cache_data(ttl=900, show_spinner=False)
def cached_query(_conn, sql_text, params=None, cache_key=None):
    df = run_query(_conn, sql_text, params)
    return normalize_date_column(df)


def normalize_date_column(df, col="USAGE_DATE"):
    """Coerce a date-like column to timezone-naive datetimes, matching the
    same pattern used for Snowflake (usage_start_time/usage_end_time are
    timestamps and could come back tz-aware depending on driver settings)."""
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

    workspaces = ["prod-analytics", "dev-sandbox", "ml-platform"]
    clusters = {
        "0101-etl-cluster": "ETL Interactive Cluster",
        "0102-ds-cluster": "Data Science Cluster",
        "0103-adhoc-cluster": "Ad Hoc Cluster",
    }
    warehouses = {
        "wh-bi-serverless": "BI Serverless Warehouse",
        "wh-analytics-pro": "Analytics Pro Warehouse",
    }
    users = ["jsmith@example.com", "svc-etl@example.com", "adiaz@example.com", "mchen@example.com", "svc-bi@example.com"]
    tags = ["team:finance", "team:marketing", "env:prod", "env:dev", None]

    sku_catalog = [
        ("STANDARD_ALL_PURPOSE_COMPUTE", "All-Purpose Compute", 0.55, "cluster"),
        ("PREMIUM_ALL_PURPOSE_COMPUTE", "All-Purpose Compute", 0.65, "cluster"),
        ("STANDARD_JOBS_COMPUTE", "Jobs Compute", 0.30, "cluster"),
        ("ENTERPRISE_JOBS_COMPUTE_(PHOTON)", "Jobs Compute", 0.40, "cluster"),
        ("SERVERLESS_SQL_COMPUTE", "SQL Warehouses", 0.70, "warehouse"),
        ("STANDARD_SQL_COMPUTE", "SQL Warehouses", 0.55, "warehouse"),
        ("STANDARD_DLT_CORE_COMPUTE", "DLT / Lakeflow", 0.45, "cluster"),
        ("SERVERLESS_MODEL_SERVING", "Model Serving / AI", 0.35, "none"),
        ("SERVERLESS_VECTOR_SEARCH", "Vector Search", 0.15, "none"),
    ]
    prices = {sku: round(rng.uniform(0.10, 0.90), 4) for sku, *_ in sku_catalog}

    rows = []
    for d in days:
        for sku, category, base_dbu, resource_kind in sku_catalog:
            n_records = rng.integers(3, 12)
            for _ in range(n_records):
                dbu = max(0, rng.normal(base_dbu, base_dbu * 0.35))
                ws = rng.choice(workspaces)
                user = rng.choice(users)
                tag = rng.choice(tags)
                cluster_id = rng.choice(list(clusters.keys())) if resource_kind == "cluster" else None
                warehouse_id = rng.choice(list(warehouses.keys())) if resource_kind == "warehouse" else None
                rows.append(
                    {
                        "USAGE_DATE": d,
                        "WORKSPACE_ID": ws,
                        "SKU_NAME": sku,
                        "CATEGORY": category,
                        "USAGE_QUANTITY": dbu,
                        "LIST_PRICE": prices[sku],
                        "COST_USD": dbu * prices[sku],
                        "CLUSTER_ID": cluster_id,
                        "CLUSTER_NAME": clusters.get(cluster_id),
                        "WAREHOUSE_ID": warehouse_id,
                        "WAREHOUSE_NAME": warehouses.get(warehouse_id),
                        "RUN_AS": user,
                        "TAG": tag,
                    }
                )
    usage_df = pd.DataFrame(rows)
    return {"usage": usage_df, "_diagnostics": []}


# --------------------------------------------------------------------------
# Live data loaders (system table queries)
# --------------------------------------------------------------------------
def load_live_data(conn, start_date, end_date, tag_key):
    diagnostics = []
    params = {"start": start_date, "end": end_date}

    # Join usage against list_prices using the pattern from Databricks' own
    # docs: match on sku_name and pick the price whose validity window
    # covers usage_end_time. custom_tags is a map column, so the tag key to
    # break down by is a user-supplied parameter, not a fixed column name.
    tag_select = "u.custom_tags[:tag_key]" if tag_key else "NULL"
    usage_sql = f"""
        SELECT
            u.usage_date AS USAGE_DATE,
            u.workspace_id AS WORKSPACE_ID,
            u.sku_name AS SKU_NAME,
            u.usage_quantity AS USAGE_QUANTITY,
            p.pricing.effective_list.default AS LIST_PRICE,
            u.usage_quantity * p.pricing.effective_list.default AS COST_USD,
            u.usage_metadata.cluster_id AS CLUSTER_ID,
            u.usage_metadata.warehouse_id AS WAREHOUSE_ID,
            u.usage_metadata.job_id AS JOB_ID,
            u.identity_metadata.run_as AS RUN_AS,
            {tag_select} AS TAG
        FROM system.billing.usage u
        JOIN system.billing.list_prices p
          ON p.sku_name = u.sku_name
         AND u.usage_end_time >= p.price_start_time
         AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
        WHERE u.usage_date BETWEEN :start AND :end
    """
    if tag_key:
        params["tag_key"] = tag_key
    try:
        usage_df = cached_query(conn, usage_sql, params, cache_key=("usage", start_date, end_date, tag_key))
        usage_df["CATEGORY"] = usage_df["SKU_NAME"].apply(classify_sku)
    except Exception as e:
        diagnostics.append(("Usage + pricing (system.billing.usage / list_prices)", str(e)))
        usage_df = pd.DataFrame(
            columns=["USAGE_DATE", "WORKSPACE_ID", "SKU_NAME", "USAGE_QUANTITY", "LIST_PRICE",
                     "COST_USD", "CLUSTER_ID", "WAREHOUSE_ID", "JOB_ID", "RUN_AS", "TAG", "CATEGORY"]
        )

    # Cluster name lookup (SCD table — take the most recently-known name per ID)
    clusters_sql = """
        SELECT cluster_id AS CLUSTER_ID, cluster_name AS CLUSTER_NAME
        FROM (
            SELECT cluster_id, cluster_name,
                   ROW_NUMBER() OVER (PARTITION BY cluster_id ORDER BY create_time DESC) AS rn
            FROM system.compute.clusters
        ) t
        WHERE rn = 1
    """
    try:
        clusters_df = cached_query(conn, clusters_sql, cache_key=("clusters",))
    except Exception as e:
        diagnostics.append(("Cluster names (system.compute.clusters)", str(e)))
        clusters_df = pd.DataFrame(columns=["CLUSTER_ID", "CLUSTER_NAME"])

    warehouses_sql = """
        SELECT DISTINCT warehouse_id AS WAREHOUSE_ID, warehouse_name AS WAREHOUSE_NAME
        FROM system.compute.warehouses
    """
    try:
        warehouses_df = cached_query(conn, warehouses_sql, cache_key=("warehouses",))
    except Exception as e:
        diagnostics.append(("Warehouse names (system.compute.warehouses)", str(e)))
        warehouses_df = pd.DataFrame(columns=["WAREHOUSE_ID", "WAREHOUSE_NAME"])

    if not usage_df.empty:
        if not clusters_df.empty:
            usage_df = usage_df.merge(clusters_df, on="CLUSTER_ID", how="left")
        else:
            usage_df["CLUSTER_NAME"] = None
        if not warehouses_df.empty:
            usage_df = usage_df.merge(warehouses_df, on="WAREHOUSE_ID", how="left")
        else:
            usage_df["WAREHOUSE_NAME"] = None

    return {"usage": usage_df, "_diagnostics": diagnostics}


# --------------------------------------------------------------------------
# Cost aggregation helpers
# --------------------------------------------------------------------------
@dataclass
class PricingConfig:
    discount_pct: float = 0.0  # applied uniformly on top of list price, e.g. for committed-use discounts


def apply_discount(usage_df, pricing: PricingConfig):
    df = usage_df.copy()
    if not df.empty:
        df["COST_USD"] = df["COST_USD"] * (1 - pricing.discount_pct / 100.0)
    return df


def apply_filters(usage_df, workspaces, clusters, warehouses, users, tags):
    df = usage_df.copy()
    if workspaces:
        df = df[df["WORKSPACE_ID"].isin(workspaces)]
    if clusters:
        df = df[df["CLUSTER_NAME"].isin(clusters) | df["CLUSTER_ID"].isin(clusters)]
    if warehouses:
        df = df[df["WAREHOUSE_NAME"].isin(warehouses) | df["WAREHOUSE_ID"].isin(warehouses)]
    if users:
        df = df[df["RUN_AS"].isin(users)]
    if tags:
        df = df[df["TAG"].isin(tags)]
    return df


# --------------------------------------------------------------------------
# Sidebar: connection
# --------------------------------------------------------------------------
st.sidebar.title("🧱 Databricks Cost Explorer")

_conn, is_apps = get_connection()

with st.sidebar.expander(
    "🔌 Connection",
    expanded=not is_apps and "db_conn" not in st.session_state,
):
    if is_apps:
        st.success("Running inside Databricks Apps — using the platform's injected credentials automatically.")
        demo_mode = st.checkbox("Use demo data instead", value=False)
    else:
        demo_mode = st.checkbox("Use demo data (no connection)", value=True)

        if not demo_mode:
            host = st.text_input("Workspace URL", placeholder="adb-1234567890123456.7.azuredatabricks.net")
            http_path = st.text_input("SQL Warehouse HTTP path", placeholder="/sql/1.0/warehouses/abcdef1234567890")
            token = st.text_input("Personal access token", type="password")

            if st.button("Connect", use_container_width=True):
                try:
                    with st.spinner("Connecting to Databricks..."):
                        new_conn = try_connect(host, http_path, token)
                    st.session_state["db_conn"] = new_conn
                    st.success("Connected.")
                except Exception as e:
                    st.error(f"Connection failed: {e}")

            if st.session_state.get("db_conn"):
                if st.button("Disconnect", use_container_width=True):
                    try:
                        st.session_state["db_conn"].close()
                    except Exception:
                        pass
                    del st.session_state["db_conn"]
                    st.rerun()

with st.sidebar.expander("💲 Pricing assumptions"):
    discount_pct = st.number_input(
        "Committed-use discount %",
        min_value=0.0,
        max_value=100.0,
        value=0.0,
        step=1.0,
        help="Applied uniformly on top of list price from system.billing.list_prices. "
        "Set this if your account has a negotiated discount off list price.",
    )
    tag_key = st.text_input(
        "Tag key to break down by",
        value="team",
        help="custom_tags is a key/value map on each usage record — enter the tag key "
        "you use for cost allocation (e.g. 'team', 'cost-center', 'project').",
    )

pricing = PricingConfig(discount_pct=discount_pct)

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
    "Last 365 days": (today - dt.timedelta(days=365), today),
    "Custom range": None,
}
preset_label = st.sidebar.selectbox("Date range preset", list(DATE_PRESETS.keys()))
if DATE_PRESETS[preset_label] is not None:
    start_date, end_date = DATE_PRESETS[preset_label]
    st.sidebar.caption(f"{start_date:%b %d, %Y} – {end_date:%b %d, %Y}")
else:
    date_range = st.sidebar.date_input("Custom date range", value=(first_of_month, today), max_value=today)
    if isinstance(date_range, tuple) and len(date_range) == 2:
        start_date, end_date = date_range
    else:
        start_date, end_date = first_of_month, today

# --------------------------------------------------------------------------
# Load data
# --------------------------------------------------------------------------
if demo_mode or _conn is None:
    if not demo_mode and _conn is None:
        st.sidebar.warning("Not connected — showing demo data.")
    raw_data = generate_mock_data(start_date, end_date)
else:
    try:
        raw_data = load_live_data(_conn, start_date, end_date, tag_key)
    except Exception as e:
        st.sidebar.error(f"Query failed, falling back to demo data: {e}")
        raw_data = generate_mock_data(start_date, end_date)

_diagnostics = raw_data.get("_diagnostics", [])
if _diagnostics:
    with st.expander(f"⚠️ {len(_diagnostics)} data source issue(s) — click for details", expanded=True):
        st.caption(
            "Common causes: the running identity lacks SELECT on the system schema (an "
            "account admin + metastore admin must grant `USE`/`SELECT` on `system.billing` "
            "and `system.compute`), a table isn't enabled yet (system schemas must be "
            "explicitly enabled per-schema), or there's a genuine SQL error below."
        )
        for label, error_text in _diagnostics:
            st.markdown(f"**{label}**")
            st.code(error_text, language=None)

usage_df = apply_discount(raw_data["usage"], pricing)

# --------------------------------------------------------------------------
# Sidebar: dimension filters
# --------------------------------------------------------------------------
st.sidebar.markdown("---")
st.sidebar.subheader("Filters")

workspace_opts = sorted(usage_df["WORKSPACE_ID"].dropna().unique().tolist()) if not usage_df.empty else []
cluster_opts = sorted(usage_df["CLUSTER_NAME"].dropna().unique().tolist()) if not usage_df.empty and "CLUSTER_NAME" in usage_df else []
warehouse_opts = sorted(usage_df["WAREHOUSE_NAME"].dropna().unique().tolist()) if not usage_df.empty and "WAREHOUSE_NAME" in usage_df else []
user_opts = sorted(usage_df["RUN_AS"].dropna().unique().tolist()) if not usage_df.empty else []
tag_opts = sorted(usage_df["TAG"].dropna().unique().tolist()) if not usage_df.empty else []

sel_workspaces = st.sidebar.multiselect("Workspace", workspace_opts)
sel_clusters = st.sidebar.multiselect("Cluster", cluster_opts)
sel_warehouses = st.sidebar.multiselect("SQL Warehouse", warehouse_opts)
sel_users = st.sidebar.multiselect("User", user_opts)
sel_tags = st.sidebar.multiselect(f"Tag ({tag_key})" if tag_key else "Tag", tag_opts)

filtered_df = apply_filters(usage_df, sel_workspaces, sel_clusters, sel_warehouses, sel_users, sel_tags)

# --------------------------------------------------------------------------
# Header / KPIs
# --------------------------------------------------------------------------
st.title("Databricks Cost Breakdown")
st.caption(f"{start_date:%b %d, %Y} – {end_date:%b %d, %Y}")

total_cost = filtered_df["COST_USD"].sum() if not filtered_df.empty else 0.0

if not filtered_df.empty:
    by_cat = filtered_df.groupby("CATEGORY", as_index=False)["COST_USD"].sum().sort_values("COST_USD", ascending=False)
    top_category = by_cat.iloc[0]["CATEGORY"] if not by_cat.empty else "—"
    top_category_cost = by_cat.iloc[0]["COST_USD"] if not by_cat.empty else 0.0
else:
    top_category, top_category_cost = "—", 0.0

period_len = (end_date - start_date).days + 1
prev_start = start_date - dt.timedelta(days=period_len)
prev_end = start_date - dt.timedelta(days=1)
if demo_mode or _conn is None:
    prev_raw = generate_mock_data(prev_start, prev_end, seed=7)
else:
    try:
        prev_raw = load_live_data(_conn, prev_start, prev_end, tag_key)
    except Exception:
        prev_raw = generate_mock_data(prev_start, prev_end, seed=7)
prev_df = apply_discount(prev_raw["usage"], pricing)
prev_total = prev_df["COST_USD"].sum() if not prev_df.empty else 0.0
mom_pct = ((total_cost - prev_total) / prev_total * 100) if prev_total else 0.0

k1, k2, k3, k4 = st.columns(4)
k1.metric("Total estimated cost", f"${total_cost:,.0f}")
k2.metric("Vs. prior period", f"{mom_pct:+.1f}%")
k3.metric("Top cost driver", top_category, f"${top_category_cost:,.0f}")
k4.metric("Total DBUs", f"{filtered_df['USAGE_QUANTITY'].sum():,.1f}" if not filtered_df.empty else "0")

st.markdown("---")

# --------------------------------------------------------------------------
# Category breakdown charts
# --------------------------------------------------------------------------
c1, c2 = st.columns([1, 1.4])

with c1:
    st.subheader("Cost by category")
    if not filtered_df.empty:
        pie_df = filtered_df.groupby("CATEGORY", as_index=False)["COST_USD"].sum()
        fig = px.pie(pie_df, names="CATEGORY", values="COST_USD", color="CATEGORY",
                     color_discrete_map=CATEGORY_COLORS, hole=0.45)
        fig.update_traces(textinfo="percent+label")
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("No data for the selected period.")

with c2:
    st.subheader("Daily cost trend by category")
    if not filtered_df.empty:
        trend = filtered_df.groupby(["USAGE_DATE", "CATEGORY"], as_index=False)["COST_USD"].sum()
        fig = px.bar(trend, x="USAGE_DATE", y="COST_USD", color="CATEGORY",
                     color_discrete_map=CATEGORY_COLORS, category_orders={"CATEGORY": CATEGORY_ORDER})
        fig.update_layout(barmode="stack", xaxis_title=None, yaxis_title="Cost (USD)")
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("No data for the selected period.")

st.markdown("---")

# --------------------------------------------------------------------------
# SKU breakdown (analogous to Snowflake's "compute by service type")
# --------------------------------------------------------------------------
st.subheader("⚙️ Breakdown by SKU")

show_sku_breakdown = st.checkbox(
    "Break down cost by SKU",
    value=False,
    help="Shows the granular sku_name values underlying each category — useful for spotting "
    "e.g. Photon vs non-Photon, or serverless vs classic pricing tiers.",
)
if show_sku_breakdown:
    if filtered_df.empty:
        st.info("No SKU data available for this period/account.")
    else:
        sku_opts = sorted(filtered_df["SKU_NAME"].dropna().unique().tolist())
        selected_skus = st.multiselect("SKUs to include", sku_opts, default=sku_opts)
        sku_df = filtered_df[filtered_df["SKU_NAME"].isin(selected_skus)]

        s1, s2 = st.columns([1, 1.4])
        with s1:
            pie_df = sku_df.groupby("SKU_NAME", as_index=False)["COST_USD"].sum()
            fig = px.pie(pie_df, names="SKU_NAME", values="COST_USD", hole=0.45)
            fig.update_traces(textinfo="percent+label")
            st.plotly_chart(fig, use_container_width=True)
        with s2:
            trend = sku_df.groupby(["USAGE_DATE", "SKU_NAME"], as_index=False)["COST_USD"].sum()
            fig = px.bar(trend, x="USAGE_DATE", y="COST_USD", color="SKU_NAME")
            fig.update_layout(barmode="stack", xaxis_title=None, yaxis_title="Cost (USD)")
            st.plotly_chart(fig, use_container_width=True)

        table = sku_df.groupby("SKU_NAME", as_index=False).agg(
            DBUS=("USAGE_QUANTITY", "sum"), COST_USD=("COST_USD", "sum")
        ).sort_values("COST_USD", ascending=False)
        st.dataframe(
            table.rename(columns={"SKU_NAME": "SKU", "DBUS": "DBUs", "COST_USD": "Est. Cost ($)"}),
            use_container_width=True, hide_index=True,
        )

st.markdown("---")

# --------------------------------------------------------------------------
# Cost deep-dive: selectable dimension
# --------------------------------------------------------------------------
st.subheader("🔎 Cost deep-dive")

DIMENSION_OPTIONS = {
    "Workspace": "WORKSPACE_ID",
    "Cluster": "CLUSTER_NAME",
    "SQL Warehouse": "WAREHOUSE_NAME",
    "User": "RUN_AS",
    "Tag": "TAG",
}
selected_label = st.radio("View cost breakdown by:", list(DIMENSION_OPTIONS.keys()), horizontal=True)
dim_col = DIMENSION_OPTIONS[selected_label]

if filtered_df.empty or dim_col not in filtered_df.columns:
    st.info("No data available for this breakdown with the current filters.")
else:
    dim_df = filtered_df.copy()
    dim_df[dim_col] = dim_df[dim_col].fillna(f"(no {selected_label.lower()})")

    totals = dim_df.groupby(dim_col, as_index=False)["COST_USD"].sum().sort_values("COST_USD", ascending=False)
    top_values = totals[dim_col].head(20).tolist()
    plot_df = dim_df[dim_df[dim_col].isin(top_values)]

    d1, d2 = st.columns([1.4, 1])
    with d1:
        fig = px.bar(plot_df, x=dim_col, y="COST_USD", color="CATEGORY",
                     color_discrete_map=CATEGORY_COLORS, category_orders={dim_col: top_values})
        fig.update_layout(barmode="stack", xaxis_title=None, yaxis_title="Est. cost (USD)")
        st.plotly_chart(fig, use_container_width=True)
    with d2:
        st.dataframe(
            totals.rename(columns={dim_col: selected_label, "COST_USD": "Est. Cost ($)"}),
            use_container_width=True, hide_index=True,
        )

    if dim_col in ("CLUSTER_NAME", "WAREHOUSE_NAME"):
        st.caption(
            f"{selected_label} is only populated for usage attributable to a specific "
            f"{selected_label.lower()} — serverless SKUs like Model Serving and Vector "
            "Search don't run on a named cluster or warehouse, so they won't appear here."
        )

st.markdown("---")

# --------------------------------------------------------------------------
# Detail & export
# --------------------------------------------------------------------------
st.subheader("📄 Detail & export")
if not filtered_df.empty:
    st.dataframe(filtered_df, use_container_width=True, hide_index=True)
    st.download_button(
        "Download usage detail CSV",
        filtered_df.to_csv(index=False).encode("utf-8"),
        file_name=f"databricks_usage_{start_date}_{end_date}.csv",
        mime="text/csv",
    )
else:
    st.info("No data to display.")

st.markdown("---")
st.caption(
    "Cost figures are estimates using list prices from system.billing.list_prices, adjusted "
    "by the discount % set in the sidebar. Actual billing may differ — reconcile against your "
    "Databricks invoice for exact figures. Storage isn't shown here since Databricks doesn't "
    "bill for it directly; check your cloud provider's billing for S3/ADLS/GCS costs."
)
