import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session

# Set up page layout
st.set_page_config(layout="wide")
st.title("Cortex Code (Snowsight) Usage Monitor")
st.caption("Track credit consumption and activity metrics for CoCo inside Snowsight worksheets.")

# Initialize Snowpark Session
session = get_active_session()

# --- SIDEBAR FILTERS ---
st.sidebar.header("Filter Options")

# Fetch unique user login names by joining with the account usage users table
try:
    users_df = session.sql("""
                           SELECT DISTINCT u.LOGIN_NAME
                           FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY h
                                    JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
                           WHERE u.LOGIN_NAME IS NOT NULL
                           """).to_pandas()
    user_list = ["All Users"] + users_df["LOGIN_NAME"].tolist()
except Exception:
    user_list = ["All Users"]

selected_user = st.sidebar.selectbox("Select User", user_list)
days_to_monitor = st.sidebar.slider("Lookback Period (Days)", min_value=1, max_value=90, value=30)

# --- CORRECTED QUERY BUILDING ---
base_query = f"""
    SELECT 
        h.USAGE_TIME,
        u.LOGIN_NAME AS USER_NAME,
        h.TOKEN_CREDITS,
        h.REQUEST_ID
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY h
    LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
    WHERE h.USAGE_TIME >= DATEADD(day, -{days_to_monitor}, CURRENT_TIMESTAMP())
"""

if selected_user != "All Users":
    base_query += f" AND u.LOGIN_NAME = '{selected_user}'"

# Fetch Data
@st.cache_data(ttl=600)
def load_usage_data(query):
    return session.sql(query).to_pandas()

try:
    df = load_usage_data(base_query)

    if df.empty:
        st.warning("No Cortex Code usage data found for the selected timeframe or user.")
    else:
        # Convert timestamps for proper visualization
        df['USAGE_TIME'] = pd.to_datetime(df['USAGE_TIME'])
        df['DATE'] = df['USAGE_TIME'].dt.date

        # --- KPI METRICS ---
        total_credits = df['TOKEN_CREDITS'].sum()
        total_prompts = len(df)
        unique_users = df['USER_NAME'].nunique()

        col1, col2, col3 = st.columns(3)
        col1.metric("Total Billable Credits", f"{total_credits:.4f}")
        col2.metric("Total Assistant Interactions", f"{total_prompts:,}")
        col3.metric("Active Developers", f"{unique_users}")

        st.markdown("---")

        # --- VISUALIZATIONS ---
        left_col, right_col = st.columns(2)

        with left_col:
            st.subheader("Daily Credit Consumption Trend")
            daily_credits = df.groupby('DATE')['TOKEN_CREDITS'].sum().reset_index()
            st.line_chart(data=daily_credits, x='DATE', y='TOKEN_CREDITS')

        with right_col:
            st.subheader("Top Users by Credit Consumption")
            user_credits = df.groupby('USER_NAME')['TOKEN_CREDITS'].sum().reset_index()
            user_credits = user_credits.sort_values(by='TOKEN_CREDITS', ascending=False).head(10)
            st.bar_chart(data=user_credits, x='USER_NAME', y='TOKEN_CREDITS')

        st.markdown("---")

        # --- RAW DATA TABLE ---
        st.subheader("Detailed Usage Audit Log")
        st.dataframe(
            df[['USAGE_TIME', 'USER_NAME', 'TOKEN_CREDITS', 'REQUEST_ID']].sort_values(by='USAGE_TIME', ascending=False),
            use_container_width=True
        )

except Exception as e:
    st.error(f"Error loading usage history: {e}")
    st.info("Ensure your active warehouse is running and your current role has SELECT access rights on the SNOWFLAKE share schemas.")

