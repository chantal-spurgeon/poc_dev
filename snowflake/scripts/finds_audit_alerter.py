#!/usr/bin/env python3
"""
FinOps Snowflake Audit Automation & Slack Alerting Utility
Requirements: pip install snowflake-connector-python requests
"""

import os
import json
import logging
import requests
import snowflake.connector

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# ============================================================================
# CONFIGURATION & ENVIRONMENT VARIABLES
# ============================================================================
SNOWFLAKE_USER = os.getenv("SF_USER")
SNOWFLAKE_PASSWORD = os.getenv("SF_PASSWORD")
SNOWFLAKE_ACCOUNT = os.getenv("SF_ACCOUNT")  # Format: "xy12345.us-east-1"
SNOWFLAKE_WH = os.getenv("SF_WAREHOUSE")
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL")

# Configuration Dict
CONFIG = {
    "lookback_days": 1,
    "runaway_threshold_minutes": 30
}

# ============================================================================
# CORE FINOPS AUDIT SQL QUERIES
# ============================================================================
RUNAWAY_QUERIES_SQL = f"""
SELECT 
    query_id,
    warehouse_name,
    user_name,
    ROUND(execution_time / 1000 / 60, 2) AS execution_time_minutes
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD(day, -{CONFIG['lookback_days']}, CURRENT_TIMESTAMP())
  AND execution_time > ({CONFIG['runaway_threshold_minutes']} * 60 * 1000)
  AND execution_status = 'SUCCESS'
ORDER BY execution_time DESC
LIMIT 5;
"""

IDLE_WASTE_SQL = f"""
WITH warehouse_hourly_usage AS (
    SELECT 
        warehouse_name,
        DATE_TRUNC('hour', start_time) AS usage_hour,
        SUM(credits_used) AS total_credits_spent
    FROM snowflake.account_usage.warehouse_metering_history
    WHERE start_time >= DATEADD(day, -{CONFIG['lookback_days']}, CURRENT_TIMESTAMP())
    GROUP BY 1, 2
),
warehouse_hourly_execution AS (
    SELECT 
        warehouse_name,
        DATE_TRUNC('hour', start_time) AS execution_hour,
        COUNT(query_id) AS total_queries_executed,
        SUM(execution_time) AS total_active_execution_ms
    FROM snowflake.account_usage.query_history
    WHERE start_time >= DATEADD(day, -{CONFIG['lookback_days']}, CURRENT_TIMESTAMP())
    GROUP BY 1, 2
)
SELECT 
    u.warehouse_name,
    ROUND(u.total_credits_spent, 2) AS credits_spent,
    ROUND(COALESCE(e.total_active_execution_ms, 0) / 1000 / 60, 2) AS active_execution_minutes
FROM warehouse_hourly_usage u
LEFT JOIN warehouse_hourly_execution e 
    ON u.warehouse_name = e.warehouse_name 
   AND u.usage_hour = e.execution_hour
WHERE e.total_queries_executed IS NULL 
   OR (e.total_active_execution_ms / 1000 / 60) < 5
ORDER BY credits_spent DESC
LIMIT 5;
"""

# ============================================================================
# EXECUTION & DISPATCH LOGIC
# ============================================================================
def run_finops_audit():
    if not all([SNOWFLAKE_USER, SNOWFLAKE_PASSWORD, SNOWFLAKE_ACCOUNT, SLACK_WEBHOOK_URL]):
        logging.error("Missing critical environment configuration variables.")
        return

    try:
        logging.info("Establishing secure connection to Snowflake...")
        ctx = snowflake.connector.connect(
            user=SNOWFLAKE_USER,
            password=SNOWFLAKE_PASSWORD,
            account=SNOWFLAKE_ACCOUNT,
            warehouse=SNOWFLAKE_WH
        )
        cs = ctx.cursor()
    except Exception as e:
        logging.error(f"Failed to connect to Snowflake: {str(e)}")
        return

    slack_blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": "🛑 FinOps Infrastructure Alert: Cost Anomalies Detected"}
        },
        {"type": "divider"}
    ]
    
    anomalies_found = False

    # 1. Check Runaway Queries
    try:
        logging.info("Auditing for runaway queries...")
        cs.execute(RUNAWAY_QUERIES_SQL)
        runaway_rows = cs.fetchall()
        if runaway_rows:
            anomalies_found = True
            text_block = "*The following queries exceeded the execution threshold:*\n"
            for row in runaway_rows:
                text_block += f"• *ID:* `{row[0]}` | *WH:* `{row[1]}` | *User:* `{row[2]}` | *Duration:* `{row[3]} mins`\n"
            slack_blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text_block}})
    except Exception as e:
        logging.error(f"Error executing runaway queries audit: {str(e)}")

    # 2. Check Idle Warehouse Waste
    try:
        logging.info("Auditing for idle warehouse compute waste...")
        cs.execute(IDLE_WASTE_SQL)
        idle_rows = cs.fetchall()
        if idle_rows:
            anomalies_found = True
            text_block = "*The following warehouses spent credits with minimal or zero query execution:*\n"
            for row in idle_rows:
                text_block += f"• *Warehouse:* `{row[0]}` | *Credits Wasted:* `{row[1]}` | *Active Query Time:* `{row[2]} mins`\n"
            slack_blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text_block}})
    except Exception as e:
        logging.error(f"Error executing idle compute audit: {str(e)}")

    # Clean up connections
    cs.close()
    ctx.close()

    # Dispatch to Slack if issues exist
    if anomalies_found:
        logging.info("Anomalies verified. Dispatching alert block to Slack...")
        payload = {"blocks": slack_blocks}
        response = requests.post(SLACK_WEBHOOK_URL, data=json.dumps(payload), headers={'Content-Type': 'application/json'})
        if response.status_code == 200:
            logging.info("Slack alert successfully transmitted.")
        else:
            logging.error(f"Slack webhook post failed with code: {response.status_code}, Response: {response.text}")
    else:
        logging.info("FinOps audit complete. Zero architectural anomalies detected over lookback window.")

if __name__ == "__main__":
    run_finops_audit()
