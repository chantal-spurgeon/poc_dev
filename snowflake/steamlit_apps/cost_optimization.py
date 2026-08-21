import streamlit as st
from snowflake.snowpark.context import get_active_session
import pandas as pd

# 1. Page Configuration & Layout
st.set_page_config(layout="wide", page_title="FinOps Cost Optimization Dashboard")
st.title("Cloud FinOps Optimization Dashboard")
st.caption("Identifying compute inefficiencies, storage spilling, and compilation bottlenecks.")

# 2. Establish Active Snowflake Session
session = get_active_session()

# 3. Sidebar Filters
st.sidebar.header("Filter Options")

# Fetch unique warehouses dynamically for the dropdown
wh_options_df = session.sql("SELECT DISTINCT WAREHOUSE_NAME FROM FINOPS_QUERY_INSIGHTS ORDER BY 1").to_pandas()
wh_list = ["All"] + wh_options_df["WAREHOUSE_NAME"].tolist()
selected_wh = st.sidebar.selectbox("Select Virtual Warehouse", wh_list)

# Filter by anomaly category
category_list = ["All", "DISK_SPILLING", "COMPILATION_BOTTLENECK", "LONG_RUNNING"]
selected_category = st.sidebar.selectbox("Select Optimization Category", category_list)

# 4. Build Dynamic SQL Query based on Filter Selections
query = "SELECT * FROM FINOPS_QUERY_INSIGHTS WHERE 1=1"
params = []

if selected_wh != "All":
    query += f" AND WAREHOUSE_NAME = '{selected_wh}'"
if selected_category != "All":
    query += f" AND INSIGHT_CATEGORY = '{selected_category}'"

query += " ORDER BY LOGGED_AT DESC"

# Load data into memory as a Pandas DataFrame for Streamlit elements
df = session.sql(query).to_pandas()

# 5. Executive Summary Metrics (KPI Blocks)
if not df.empty:
    total_anomalies = len(df)
    spill_count = len(df[df["INSIGHT_CATEGORY"] == "DISK_SPILLING"])
    compile_count = len(df[df["INSIGHT_CATEGORY"] == "COMPILATION_BOTTLENECK"])
    
    col1, col2, col3 = st.columns(3)
    with col1:
        st.metric(label="Total Flagged Inefficiencies", value=total_anomalies)
    with col2:
        st.metric(label="Memory Spilling Queries", value=spill_count, delta="Action Required", delta_color="inverse")
    with col3:
        st.metric(label="Compilation Bottlenecks", value=compile_count)

    st.markdown("---")

    # 6. Interactive Visual Data Analysis
    left_col, right_col = st.columns(2)

    with left_col:
        st.subheader("Inefficiencies by Warehouse")
        if "WAREHOUSE_NAME" in df.columns:
            wh_counts = df["WAREHOUSE_NAME"].value_counts()
            st.bar_chart(wh_counts)

    with right_col:
        st.subheader("Distribution of Insight Categories")
        if "INSIGHT_CATEGORY" in df.columns:
            cat_counts = df["INSIGHT_CATEGORY"].value_counts()
            st.bar_chart(cat_counts)

    st.markdown("---")

    # 7. Actionable Query Optimization Blueprint Table
    st.subheader("Targeted Query Refactoring Queue")
    st.markdown("Share this list with development teams to optimize warehouse credit consumption.")
    
    # Format layout for easy scannability
    formatted_df = df[[
        "QUERY_ID", "USER_NAME", "WAREHOUSE_NAME", 
        "TOTAL_ELAPSED_TIME_MINUTES", "INSIGHT_CATEGORY", "RECOMMENDATION"
    ]]
    
    st.dataframe(
        formatted_df,
        column_config={
            "QUERY_ID": "Query ID",
            "USER_NAME": "Executing User",
            "WAREHOUSE_NAME": "Warehouse",
            "TOTAL_ELAPSED_TIME_MINUTES": st.column_config.NumberColumn("Duration (Min)", format="%.2f"),
            "INSIGHT_CATEGORY": "Issue Identified",
            "RECOMMENDATION": "Actionable Remediation Step"
        },
        hide_index=True,
        use_container_width=True
    )

else:
    st.success("Clean Check! No query inefficiencies or cost anomalies detected with the current filter settings.")
