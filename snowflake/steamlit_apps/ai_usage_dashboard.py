"""My Cortex AI Usage: self-service view of AI credits vs the monthly budget.

Replaces current.py. Same purpose and tabs, but:
  - reads three small tables refreshed hourly by REFRESH_AI_USAGE_DASHBOARD
    (no ACCOUNT_USAGE queries at page load), cached for 10 minutes
  - the budget, the "used" total and the status come from the same rules as
    ENFORCE_CORTEX_AI_LIMITS, so the page matches what enforcement does
  - shows whether the user's access was revoked, and CoCo daily-limit usage,
    so users can tell why requests are failing
"""

import pandas as pd
import streamlit as st

st.set_page_config(page_title="My Cortex AI Usage", layout="wide")

conn = st.connection("snowflake")
TTL = 600  # 10 min; the tables refresh hourly
SCHEMA = "AI_COST_MGMT.PUBLIC"


# On container runtime (SPCS), CURRENT_USER() and st.user return the service
# account. The SPCS proxy passes the viewer's user name in this header.
def viewer_name() -> str:
    try:
        headers = st.context.headers
        name = headers.get("Sf-Context-Current-User") or headers.get("sf-context-current-user")
        if name:
            return name
    except Exception:
        pass
    st.error("Couldn't identify you from the app session. Please contact the Snowflake admin team.")
    st.stop()


def q(sql, user=None):
    params = {"u": user} if user else None
    return conn.query(sql, params=params, ttl=TTL, show_spinner=False)


user = viewer_name()

with st.spinner("Loading your usage…"):
    meta = q(f"select max(month_start) as month_start, max(refreshed_at) as refreshed_at "
             f"from {SCHEMA}.ai_dash_user_status")
    status = q(f"""
        select tier_role, monthly_credit_limit, credits_used, status, revoked_at
          from {SCHEMA}.ai_dash_user_status
         where user_name = %(u)s
    """, user)
    usage = q(f"""
        select usage_date, source, detail, credits, counts_toward_budget
          from {SCHEMA}.ai_dash_usage_daily
         where user_name = %(u)s
    """, user)
    coco = q(f"""
        select interface, credits_24h, daily_limit, exception_expires_at
          from {SCHEMA}.ai_dash_coco_24h
         where user_name = %(u)s
    """, user)

month_start = pd.to_datetime(meta["MONTH_START"].iloc[0])
refreshed = pd.to_datetime(meta["REFRESHED_AT"].iloc[0])
next_reset = month_start + pd.offsets.MonthBegin(1)

usage["USAGE_DATE"] = pd.to_datetime(usage["USAGE_DATE"])
usage["CREDITS"] = usage["CREDITS"].astype(float)
this_month = usage[usage["USAGE_DATE"] >= month_start.normalize().tz_localize(None)]

display_user = user.split("@")[0]
st.title("My Cortex AI Usage")
st.caption(
    f"{display_user} · {month_start:%B %Y} · updated {refreshed:%b %d %H:%M}. "
    "Updates hourly; usage data can lag up to about an hour behind your activity."
)

tab1, tab2, tab3 = st.tabs(["My usage this month", "Activity detail", "Tips & cost guidance"])

# =============================================================================
# TAB 1: My usage this month
# =============================================================================
with tab1:
    # ---- Monthly budget status --------------------------------------------
    st.header("Monthly AI budget")
    limit_for_tips = None

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
            limit_for_tips = limit

            if row["STATUS"] == "REVOKED":
                st.error(
                    f"**Your AI access is paused.** {row['TIER_ROLE']} was removed on "
                    f"{pd.to_datetime(row['REVOKED_AT']):%b %d at %H:%M} after you reached your "
                    f"monthly budget. Cortex AI requests will fail until access is restored "
                    f"automatically on **{next_reset:%B %d}**."
                )
            elif row["STATUS"] == "OVER_LIMIT":
                st.error(
                    f"**You've used your monthly budget** ({used:,.2f} of {limit:,.0f} credits). "
                    "Your AI access will be paused at the next hourly check."
                )
            elif pct >= 0.8:
                st.warning(f"You've used {pct:.0%} of your monthly AI budget.")
            else:
                st.success(f"Your AI access is active ({row['TIER_ROLE']}).")

            c1, c2, c3 = st.columns(3)
            c1.metric("Counted this month", f"{used:,.2f}")
            c2.metric("Monthly budget", f"{limit:,.0f}")
            c3.metric("Remaining", f"{max(limit - used, 0):,.2f}")
            st.progress(min(pct, 1.0), text=f"{pct:.0%} of your {row['TIER_ROLE']} budget")

        st.caption(
            "Access is paused at the first hourly check after you pass your budget, so your "
            "total can end up slightly over 100%."
        )

    # ---- CoCo daily limits -------------------------------------------------
    st.header("CoCo daily limits (last 24 hours)")
    st.caption(
        "Separate from the monthly budget, each CoCo interface (Snowsight, CLI, Desktop) has "
        "its own daily credit limit over a rolling 24 hours. Hitting it blocks only that "
        "interface, and it clears as your usage moves out of the 24-hour window."
    )
    if coco.empty:
        st.write("No CoCo usage in the last 24 hours.")
    else:
        for _, row in coco.sort_values("INTERFACE").iterrows():
            used = float(row["CREDITS_24H"])
            lim = float(row["DAILY_LIMIT"])
            if lim < 0:
                st.write(f"**{row['INTERFACE']}**: {used:,.2f} credits (no daily limit: approved exception)")
                continue
            extra = ""
            if pd.notna(row["EXCEPTION_EXPIRES_AT"]):
                extra = f" · exception until {pd.to_datetime(row['EXCEPTION_EXPIRES_AT']):%b %d}"
            st.progress(min(used / lim, 1.0) if lim else 1.0,
                        text=f"{row['INTERFACE']}: {used:,.2f} of {lim:,.0f}{extra}")
            if used >= lim:
                st.warning(
                    f"You've reached the CoCo daily limit in {row['INTERFACE']}. That interface is "
                    "blocked until your usage drops back under the limit."
                )

    # ---- Breakdown by service ----------------------------------------------
    st.header("Breakdown by service")
    if this_month.empty:
        st.info("No AI usage recorded for you this month.")
    else:
        by_source = (
            this_month.groupby(["SOURCE", "COUNTS_TOWARD_BUDGET"], as_index=False)["CREDITS"].sum()
            .sort_values("CREDITS", ascending=False)
        )
        by_source["Counts toward budget"] = by_source["COUNTS_TOWARD_BUDGET"].map({True: "Yes", False: "No"})
        st.bar_chart(by_source.set_index("SOURCE")["CREDITS"])
        st.dataframe(
            by_source[["SOURCE", "CREDITS", "Counts toward budget"]]
            .rename(columns={"SOURCE": "Service", "CREDITS": "Credits"}),
            hide_index=True, use_container_width=True,
        )
        if (~by_source["COUNTS_TOWARD_BUDGET"]).any():
            st.caption("CoCo in Snowsight and Desktop is limited daily, not by the monthly budget.")

# =============================================================================
# TAB 2: Activity detail (filters the data already loaded; no new queries)
# =============================================================================
with tab2:
    st.header("My activity detail")
    days = st.slider("Days to show", 7, 30, 14, key="detail_days")
    cutoff = pd.Timestamp.now().normalize() - pd.Timedelta(days=days)
    recent = usage[usage["USAGE_DATE"] >= cutoff]

    if recent.empty:
        st.info("No AI activity in this period.")
    else:
        st.subheader("Daily credits by service")
        daily = (
            recent.pivot_table(index="USAGE_DATE", columns="SOURCE", values="CREDITS", aggfunc="sum")
            .fillna(0).sort_index()
        )
        st.bar_chart(daily)

        detail = recent.dropna(subset=["DETAIL"])
        if not detail.empty:
            st.subheader("AI Functions and REST API by model")
            st.dataframe(
                detail.groupby(["SOURCE", "DETAIL"], as_index=False)["CREDITS"].sum()
                .sort_values("CREDITS", ascending=False)
                .rename(columns={"SOURCE": "Service", "DETAIL": "Function / model", "CREDITS": "Credits"}),
                hide_index=True, use_container_width=True,
            )

# =============================================================================
# TAB 3: Tips & cost guidance (static text)
# =============================================================================
with tab3:
    st.header("Tips & cost guidance")

    st.subheader("What drives cost?")
    st.markdown("""
Context handling (not model choice) is the dominant cost driver for CoCo usage.
Each request sends context (files, conversation history, tool results) to the model.
Larger context = more tokens = more credits.

The most impactful things you can do:
- Scope your prompts tightly
- Add this to your instructions: "If a permission error occurs, stop and tell me which object and role are involved."
- Avoid open-ended exploration ("fix everything") in favor of specific tasks
""")

    st.subheader("Model selection")
    st.markdown("""
When using AI Functions directly (AI_COMPLETE, etc.), cheaper models work fine for simpler tasks:
- Simple classification/extraction: llama3.1-8b, mistral-7b (cheapest)
- General tasks: llama3.3-70b, openai-gpt-5-mini
- Complex reasoning: claude-sonnet-4-5, openai-gpt-5 (more expensive)
- CoCo model selection is automatic; you cannot control it directly
""")

    st.subheader("Understanding your limits")
    st.markdown(f"""
**Monthly budget** (set by your AI tier role). Counts AI Functions, Cortex Analyst, Cortex
Agents, Snowflake Intelligence, CoCo CLI and the Cortex REST API. When you pass it, your
AI tier role is removed at the next hourly check, and AI requests fail until it's restored
on the 1st of the month.

**CoCo daily limits.** Each CoCo interface (Snowsight, CLI, Desktop) has its own limit over a
rolling 24 hours. Reaching it blocks only that interface until your usage in the last
24 hours drops back under the limit.
""")

    st.subheader("Request a tier upgrade")
    st.markdown("If you consistently hit your limit and have a business justification, send this to your admin:")
    budget_words = f"{limit_for_tips:,.0f} credits/month" if limit_for_tips else "my current monthly budget"
    st.code(f"""Hi [Admin],

I am hitting my monthly AI budget ({budget_words}).
My current usage is primarily [describe: CoCo development / AI functions for pipeline / etc.].
I would like to request an upgrade from my current tier.

Business justification: [describe project or use case]

Thank you,
{user}
""", language="text")

    st.divider()
    st.subheader("Reference links")
    st.markdown("""
- Daily credit limits for CoCo: https://docs.snowflake.com/en/user-guide/cortex-code/credit-usage-limit
- Cost attribution: https://docs.snowflake.com/en/user-guide/cost-attributing
- Credit consumption table: https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf
""")
