"""My AI usage: self-service view of this month's Cortex AI credits vs quota.

Answers two questions for the person viewing it:
  1. How close am I to my monthly AI budget?
  2. If I'm getting errors, is it because my access was paused (monthly budget)
     or because I hit a CoCo daily limit?

Reads three small tables that ENFORCE_CORTEX_AI_LIMITS refreshes hourly:
  AI_USER_BUDGET_STATUS, AI_USAGE_DAILY, AI_COCO_24H_USAGE
No ACCOUNT_USAGE queries at page load.
"""

import pandas as pd
import streamlit as st

st.set_page_config(page_title="My AI usage", layout="centered")

conn = st.connection("snowflake")
TTL = 600  # 10 min; the tables only change hourly
SCHEMA = "AI_COST_MGMT.PUBLIC"


def viewer_name() -> str:
    """USERS.NAME of the person viewing the app."""
    try:
        name = st.user.get("user_name")
        if name:
            return name
    except Exception:
        pass
    return conn.query("select current_user() as u", ttl=3600)["U"].iloc[0]


def q(sql: str, user: str) -> pd.DataFrame:
    return conn.query(sql, params={"u": user}, ttl=TTL, show_spinner=False)


user = viewer_name()

with st.spinner("Loading your usage…"):
    status = q(f"""
        select tier_role, monthly_credit_limit, credits_used, status, revoked_at,
               month_start, refreshed_at
          from {SCHEMA}.ai_user_budget_status
         where user_name = %(u)s
    """, user)
    meta = conn.query(f"""
        select max(month_start) as month_start, max(refreshed_at) as refreshed_at
          from {SCHEMA}.ai_user_budget_status
    """, ttl=TTL, show_spinner=False)
    daily = q(f"""
        select usage_date, source, credits
          from {SCHEMA}.ai_usage_daily
         where user_name = %(u)s
           and usage_date >= (select max(month_start)::date from {SCHEMA}.ai_user_budget_status)
    """, user)
    coco = q(f"""
        select interface, credits_24h, daily_limit, exception_expires_at, refreshed_at
          from {SCHEMA}.ai_coco_24h_usage
         where user_name = %(u)s
    """, user)

month_start = pd.to_datetime(meta["MONTH_START"].iloc[0])
refreshed = pd.to_datetime(meta["REFRESHED_AT"].iloc[0])
next_reset = (month_start + pd.offsets.MonthBegin(1)) if pd.notna(month_start) else None

st.title("My AI usage")
st.caption(
    f"{user} · {month_start:%B %Y} · updated {refreshed:%b %d %H:%M}. "
    "Updates hourly. Usage data can lag up to about an hour behind your activity."
)

# ---------------------------------------------------------------------------
# Section 1: monthly budget status
# ---------------------------------------------------------------------------
st.header("Monthly AI budget")

if status.empty:
    st.info(
        "You don't currently have an AI tier role (AI_EXPLORER or AI_DATA_SCIENCE), "
        "so no monthly budget applies to you. Contact the Snowflake admin team if you need access."
    )
else:
    for _, row in status.iterrows():
        limit = float(row["MONTHLY_CREDIT_LIMIT"])
        used = float(row["CREDITS_USED"])
        pct = used / limit if limit else 0.0
        state = row["STATUS"]

        if state == "REVOKED":
            revoked_at = pd.to_datetime(row["REVOKED_AT"])
            st.error(
                f"**Your AI access is paused.** {row['TIER_ROLE']} was removed on "
                f"{revoked_at:%b %d at %H:%M} because you used {used:,.2f} of your "
                f"{limit:,.0f} monthly credits. Cortex AI and CoCo requests will fail until "
                f"access is restored automatically on **{next_reset:%B %d}**."
            )
        elif state == "OVER_LIMIT":
            st.error(
                f"**You've used your monthly budget** ({used:,.2f} of {limit:,.0f} credits). "
                "Your AI access will be paused at the next hourly check."
            )
        elif pct >= 0.8:
            st.warning(f"You've used {pct:.0%} of your monthly AI budget.")
        else:
            st.success(f"Your AI access is active ({row['TIER_ROLE']}).")

        c1, c2, c3 = st.columns(3)
        c1.metric("Used this month", f"{used:,.2f}")
        c2.metric("Monthly limit", f"{limit:,.0f}")
        c3.metric("Remaining", f"{max(limit - used, 0):,.2f}")
        st.progress(min(pct, 1.0), text=f"{pct:.0%} of {row['TIER_ROLE']} budget")

    st.caption(
        "Access is paused at the first hourly check after you pass your limit, so your "
        "total can end up slightly over 100%."
    )

# ---------------------------------------------------------------------------
# Section 2: CoCo daily limits (a different cause of errors)
# ---------------------------------------------------------------------------
st.header("CoCo daily limits (last 24 hours)")
st.caption(
    "Separate from your monthly budget, Cortex Code has a daily credit limit for each "
    "interface (Snowsight, CLI, Desktop). Hitting it blocks only that interface, and "
    "it clears as your usage drops out of the last 24 hours."
)

if coco.empty:
    st.write("No CoCo usage in the last 24 hours.")
else:
    for _, row in coco.sort_values("INTERFACE").iterrows():
        used = float(row["CREDITS_24H"])
        lim = float(row["DAILY_LIMIT"])
        label = f"**{row['INTERFACE']}**: {used:,.2f} credits"
        if lim < 0:
            st.write(f"{label} (no daily limit: approved exception)")
            continue
        pct = used / lim if lim else 0.0
        extra = ""
        if pd.notna(row["EXCEPTION_EXPIRES_AT"]):
            extra = f" · exception until {pd.to_datetime(row['EXCEPTION_EXPIRES_AT']):%b %d}"
        st.progress(min(pct, 1.0), text=f"{row['INTERFACE']}: {used:,.2f} of {lim:,.0f}{extra}")
        if pct >= 1:
            st.warning(
                f"You've reached the CoCo daily limit in {row['INTERFACE']}. "
                "That interface is blocked until usage drops out of the 24-hour window."
            )

# ---------------------------------------------------------------------------
# Section 3: where the credits went
# ---------------------------------------------------------------------------
st.header("Usage this month")
if daily.empty:
    st.write("No AI usage recorded yet this month.")
else:
    daily["CREDITS"] = daily["CREDITS"].astype(float)
    by_day = (
        daily.pivot_table(index="USAGE_DATE", columns="SOURCE", values="CREDITS", aggfunc="sum")
        .fillna(0)
        .sort_index()
    )
    st.subheader("Daily credits by source")
    st.bar_chart(by_day)

    st.subheader("By source")
    by_source = (
        daily.groupby("SOURCE", as_index=False)["CREDITS"].sum()
        .sort_values("CREDITS", ascending=False)
        .rename(columns={"SOURCE": "Source", "CREDITS": "Credits"})
    )
    st.dataframe(by_source, hide_index=True, use_container_width=True)
