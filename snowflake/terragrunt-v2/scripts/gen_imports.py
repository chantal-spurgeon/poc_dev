#!/usr/bin/env python3
"""Turn exported SHOW results into Terraform import blocks.

Export each result from Snowsight (Download as CSV) or from SnowSQL, one file per command:

    SHOW ROLES;       -> roles.csv
    SHOW WAREHOUSES;  -> warehouses.csv
    SHOW DATABASES;   -> databases.csv
    SHOW SCHEMAS IN ACCOUNT;  -> schemas.csv

Usage:
    python3 gen_imports.py EXPORT_DIR > imports.tf
    python3 gen_imports.py EXPORT_DIR --only names.txt > imports.tf

Without --only, every non-system object is emitted and you delete the ones you do not want.
With --only, names.txt lists one name per line (case-insensitive); schemas as DB.SCHEMA.

Put the output in the unit that owns those objects (roles -> rbac, warehouses ->
warehouses, databases and schemas -> databases) and run `terragrunt plan`. The
`to` addresses assume the map key in the unit's inputs is the UPPER CASE name
(schemas: "DB.SCHEMA"). After the import the plan should show no changes; if it
shows changes, the unit's inputs differ from what is in Snowflake: fix the inputs
(not the account) until it is clean.

Not covered: users and grants. Their import ids have more parts and I have not
verified the format for provider 2.22; do one by hand first.
"""
import csv
import sys
from pathlib import Path

SYSTEM_ROLES = {"ACCOUNTADMIN", "SYSADMIN", "SECURITYADMIN", "USERADMIN", "ORGADMIN", "PUBLIC"}
SYSTEM_DBS = {"SNOWFLAKE", "SNOWFLAKE_SAMPLE_DATA"}


def rows(path):
    p = Path(path)
    if not p.exists():
        return []
    with p.open(newline="", encoding="utf-8-sig") as f:
        return [{k.strip().lower(): (v or "").strip() for k, v in r.items()} for r in csv.DictReader(f)]


def block(to, ident):
    return f'import {{\n  to = {to}\n  id = "{ident}"\n}}\n'


def main(argv):
    only = None
    if "--only" in argv:
        i = argv.index("--only")
        only = {l.strip().upper() for l in Path(argv[i + 1]).read_text().splitlines() if l.strip()}
        del argv[i:i + 2]
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    d = Path(argv[0])
    want = (lambda n: True) if only is None else (lambda n: n.upper() in only)
    out = []

    for r in rows(d / "roles.csv"):
        n = r["name"].upper()
        if n in SYSTEM_ROLES or n.startswith("SNOWFLAKE") or not want(n):
            continue
        out.append(block(f'snowflake_account_role.rbac_roles["{n}"]', n))

    for r in rows(d / "warehouses.csv"):
        n = r["name"].upper()
        if want(n):
            out.append(block(f'snowflake_warehouse.managed_whs["{n}"]', n))

    for r in rows(d / "databases.csv"):
        n = r["name"].upper()
        if n in SYSTEM_DBS or r.get("kind", "STANDARD").upper() == "IMPORTED DATABASE" or not want(n):
            continue
        out.append(block(f'snowflake_database.managed_dbs["{n}"]', n))

    for r in rows(d / "schemas.csv"):
        db, sc = r["database_name"].upper(), r["name"].upper()
        if db in SYSTEM_DBS or sc == "INFORMATION_SCHEMA" or not (want(f"{db}.{sc}") or want(db) and only is None):
            continue
        # schema ids are quoted: "DB"."SCHEMA"
        out.append(block(f'snowflake_schema.managed_schemas["{db}.{sc}"]', f'\\"{db}\\".\\"{sc}\\"'))

    print("\n".join(out), end="")
    print(f"# {len(out)} import block(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
