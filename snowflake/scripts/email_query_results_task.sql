/* =============================================================================
   TEMPLATE: Run an approved query and email the results from Snowflake
   Replaces "run query -> download from Snowsight -> attach to email" with an
   auditable path: every run shows up in QUERY_HISTORY / TASK_HISTORY, and
   recipients are restricted by the notification integration.

   Replace everything in <ANGLE_BRACKETS>.
   ============================================================================= */

USE ROLE ACCOUNTADMIN;   -- or a role with CREATE INTEGRATION

/* -----------------------------------------------------------------------------
   1. Email notification integration
   - Recipients must be VERIFIED email addresses of users in this account.
   - ALLOWED_RECIPIENTS is your guardrail: anything not listed is rejected.
   ----------------------------------------------------------------------------- */
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS report_email_int
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('<person1@company.com>', '<person2@company.com>')
  COMMENT = 'Approved recipients for automated report emails';

GRANT USAGE ON INTEGRATION report_email_int TO ROLE <REPORT_ADMIN_ROLE>;

USE ROLE <REPORT_ADMIN_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <DB>.<SCHEMA>;

/* -----------------------------------------------------------------------------
   2. Approved report registry
   Only admins can write here. The procedure runs ONLY queries in this table,
   so end users can't pass arbitrary SQL through an owner's-rights procedure.
   ----------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS email_report_config (
    report_name   STRING  NOT NULL PRIMARY KEY,
    query_text    STRING  NOT NULL,
    recipients    STRING  NOT NULL,   -- comma-separated, must be in ALLOWED_RECIPIENTS
    subject       STRING  NOT NULL,
    max_rows      NUMBER  DEFAULT 500,
    is_active     BOOLEAN DEFAULT TRUE,
    owner_contact STRING,
    created_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Example report (replace with the real query from the use case)
INSERT INTO email_report_config (report_name, query_text, recipients, subject, max_rows, owner_contact)
SELECT
    'DAILY_ORDER_SUMMARY',
    $$
      SELECT order_date, region, COUNT(*) AS orders, SUM(amount) AS revenue
      FROM <DB>.<SCHEMA>.<ORDERS_TABLE>
      WHERE order_date = CURRENT_DATE() - 1
      GROUP BY 1, 2
      ORDER BY 1, 2
    $$,
    '<person1@company.com>,<person2@company.com>',
    'Daily Order Summary',
    500,
    '<requester@company.com>';

/* -----------------------------------------------------------------------------
   3. Procedure: run a registered report, render an HTML table, send the email
   - Takes only a report name, never raw SQL.
   - Caps rows (email body has a size limit; no attachments are supported).
   - Writes a row to a run log for your own audit trail.
   ----------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS email_report_log (
    run_ts        TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    report_name   STRING,
    recipients    STRING,
    row_count     NUMBER,
    truncated     BOOLEAN,
    run_by_user   STRING,
    query_id      STRING,
    status        STRING,
    error_message STRING
);

CREATE OR REPLACE PROCEDURE send_report_email(report_name STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import html

def to_html_table(columns, rows):
    # Build the HTML table by hand (no pandas dependency)
    head = "".join(f"<th>{html.escape(c)}</th>" for c in columns)
    body = "".join(
        "<tr>" + "".join(
            f"<td>{'' if v is None else html.escape(str(v))}</td>" for v in r
        ) + "</tr>"
        for r in rows
    )
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"

def run(session, report_name):
    cfg = session.sql(
        "SELECT query_text, recipients, subject, max_rows "
        "FROM email_report_config WHERE report_name = ? AND is_active",
        params=[report_name]
    ).collect()
    if not cfg:
        return f"No active report named {report_name}"
    query_text, recipients, subject, max_rows = cfg[0]
    max_rows = int(max_rows or 500)

    run_user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    try:
        # Fetch one extra row so we can tell whether results were truncated
        result = session.sql(query_text).limit(max_rows + 1)
        columns = [c.strip('"') for c in result.columns]
        rows = result.collect()
        qid = session.sql("SELECT LAST_QUERY_ID()").collect()[0][0]
        truncated = len(rows) > max_rows
        rows = rows[:max_rows]

        table_html = to_html_table(columns, rows) \
            if rows else "<p>The query returned no rows.</p>"
        note = (f"<p><b>Note:</b> results truncated to the first {max_rows} rows.</p>"
                if truncated else "")

        body = f"""
        <html><body style="font-family:Arial,sans-serif;font-size:13px">
          <p>Report: <b>{html.escape(report_name)}</b> &middot; {len(rows)} row(s)</p>
          {note}
          <style>
            table {{border-collapse:collapse}}
            th,td {{border:1px solid #ccc;padding:4px 8px;text-align:left}}
            th {{background:#f2f2f2}}
          </style>
          {table_html}
          <p style="color:#888;font-size:11px">Sent automatically from Snowflake.
          Query ID: {qid}</p>
        </body></html>
        """

        session.call("SYSTEM$SEND_EMAIL", "report_email_int",
                     recipients, subject, body, "text/html")

        session.sql(
            "INSERT INTO email_report_log (report_name, recipients, row_count, truncated, "
            "run_by_user, query_id, status) VALUES (?,?,?,?,?,?, 'SENT')",
            params=[report_name, recipients, len(rows), truncated, run_user, qid]
        ).collect()
        return f"Sent {len(rows)} row(s) to {recipients}" + (" (truncated)" if truncated else "")

    except Exception as e:
        session.sql(
            "INSERT INTO email_report_log (report_name, recipients, run_by_user, status, error_message) "
            "VALUES (?,?,?, 'FAILED', ?)",
            params=[report_name, recipients, run_user, str(e)[:4000]]
        ).collect()
        raise
$$;

/* -----------------------------------------------------------------------------
   4. Task: one per report
   Option A - scheduled: set SCHEDULE and RESUME.
   Option B - on demand only: leave it suspended and use EXECUTE TASK.
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE TASK task_email_daily_order_summary
  WAREHOUSE = <WAREHOUSE>
  SCHEDULE  = 'USING CRON 0 7 * * MON-FRI America/Chicago'   -- remove for on-demand only
  COMMENT   = 'Emails DAILY_ORDER_SUMMARY; replaces manual Snowsight download'
AS
  CALL send_report_email('DAILY_ORDER_SUMMARY');

ALTER TASK task_email_daily_order_summary RESUME;   -- skip for on-demand only

/* -----------------------------------------------------------------------------
   5. Let the requester run it themselves, without granting the underlying data
   OPERATE lets them EXECUTE TASK (and suspend/resume); they don't need
   SELECT on the source tables or the procedure.
   ----------------------------------------------------------------------------- */
GRANT USAGE   ON DATABASE <DB>             TO ROLE <REQUESTER_ROLE>;
GRANT USAGE   ON SCHEMA   <DB>.<SCHEMA>    TO ROLE <REQUESTER_ROLE>;
GRANT OPERATE ON TASK task_email_daily_order_summary TO ROLE <REQUESTER_ROLE>;

-- Requester runs on demand:
-- EXECUTE TASK <DB>.<SCHEMA>.task_email_daily_order_summary;

/* -----------------------------------------------------------------------------
   6. Monitoring / audit
   ----------------------------------------------------------------------------- */
-- Your own send log
SELECT * FROM email_report_log ORDER BY run_ts DESC;

-- Task runs (successes and failures)
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'TASK_EMAIL_DAILY_ORDER_SUMMARY'))
ORDER BY scheduled_time DESC;

-- Account-wide view of email sends
SELECT start_time, user_name, role_name, query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_text ILIKE '%SYSTEM$SEND_EMAIL%'
ORDER BY start_time DESC;
