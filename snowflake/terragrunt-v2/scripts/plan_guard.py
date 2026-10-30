#!/usr/bin/env python3
"""Fail if a Terraform plan deletes or replaces anything, and list grant changes.

Usage (per unit, from inside the unit folder, or against its cache):
    terragrunt plan -out=tfplan
    terragrunt show -json tfplan > plan.json
    python3 ../../../scripts/plan_guard.py plan.json

Exit codes: 0 = safe, 1 = deletes/replacements found, 2 = bad input.
Grants being created or revoked are reported separately: revoking a grant is a
delete in Terraform terms, so it fails the guard too unless --allow-grant-revokes.
"""
import json
import sys

GRANT_PREFIX = "snowflake_grant_"


def classify(plan):
    deletes, grant_revokes, grant_adds = [], [], []
    for rc in plan.get("resource_changes", []):
        actions = rc["change"]["actions"]
        addr = rc["address"]
        is_grant = rc["type"].startswith(GRANT_PREFIX)
        if "delete" in actions:
            (grant_revokes if is_grant and actions == ["delete"] else deletes).append((addr, actions))
        elif actions == ["create"] and is_grant:
            grant_adds.append(addr)
    return deletes, grant_revokes, grant_adds


def main(argv):
    allow_revokes = "--allow-grant-revokes" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if len(paths) != 1:
        print(__doc__)
        return 2
    try:
        plan = json.load(open(paths[0]))
    except (OSError, ValueError) as e:
        print(f"cannot read plan: {e}", file=sys.stderr)
        return 2
    deletes, revokes, adds = classify(plan)
    for a in adds:
        print(f"GRANT ADDED    {a}")
    for a, act in revokes:
        print(f"GRANT REVOKED  {a}")
    for a, act in deletes:
        kind = "REPLACED" if "create" in act else "DELETED"
        print(f"{kind:14} {a}")
    bad = bool(deletes) or (bool(revokes) and not allow_revokes)
    print("FAIL" if bad else "OK")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
