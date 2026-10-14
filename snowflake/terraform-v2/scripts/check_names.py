#!/usr/bin/env python3
"""Check that the stacks' tfvars files agree on names.

Each stack refers to the others by NAME only (a user's default warehouse, a role's
grant on a schema, ...), so Terraform cannot notice a typo across stacks until an
apply fails halfway. This reads the *.auto.tfvars files and checks every such
reference, before anything is planned. It needs only Python 3.8+ and changes nothing.

    python3 scripts/check_names.py                 # checks accounts/dev
    python3 scripts/check_names.py accounts/prod   # another account

Exit status is 1 if any name does not line up, so it can run in CI or a pre-commit hook.

It reads the tfvars files as plain data with a small parser for the subset of HCL used
there (objects, lists, strings, numbers, true/false/null). It does not evaluate
expressions or functions: if a tfvars file uses them, it says so and stops.
"""
import json
import re
import sys
from pathlib import Path

SYSTEM_ROLES = {"ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "SYSADMIN", "PUBLIC"}

# ------------------------------------------------------------------ tiny HCL reader
_TOKEN = re.compile(
    r"""
    (?P<ws>[ \t\r]+)
  | (?P<nl>\n)
  | (?P<comment>(?:\#|//)[^\n]*)
  | (?P<string>"(?:[^"\\\n]|\\.)*")
  | (?P<number>-?\d+(?:\.\d+)?)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_\-]*)
  | (?P<punct>[={}\[\],:])
    """,
    re.X,
)


class ParseError(Exception):
    pass


def _tokens(text, where):
    pos, line, out = 0, 1, []
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise ParseError(f"{where}:{line}: cannot read {text[pos:pos + 20]!r} (only plain values are supported here)")
        kind, value = m.lastgroup, m.group()
        if kind == "nl":
            out.append(("nl", value, line))
            line += 1
        elif kind not in ("ws", "comment"):
            if kind == "string" and "${" in value:
                raise ParseError(f"{where}:{line}: string interpolation is not supported by this checker")
            out.append((kind, value, line))
        pos = m.end()
    return out


class _Parser:
    def __init__(self, tokens, where):
        self.t, self.i, self.where = tokens, 0, where

    def _skip_nl(self):
        while self.i < len(self.t) and self.t[self.i][0] == "nl":
            self.i += 1

    def _peek(self):
        self._skip_nl()
        return self.t[self.i] if self.i < len(self.t) else (None, None, None)

    def _next(self):
        tok = self._peek()
        self.i += 1
        return tok

    def _expect(self, value):
        kind, v, line = self._next()
        if v != value:
            raise ParseError(f"{self.where}:{line}: expected {value!r}, found {v!r}")

    def value(self):
        kind, v, line = self._next()
        if kind == "string":
            return json.loads(v)
        if kind == "number":
            return float(v) if "." in v else int(v)
        if kind == "ident" and v in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[v]
        if v == "[":
            items = []
            while self._peek()[1] != "]":
                items.append(self.value())
                if self._peek()[1] == ",":
                    self._next()
            self._expect("]")
            return items
        if v == "{":
            obj = {}
            while self._peek()[1] != "}":
                k_kind, k, k_line = self._next()
                if k_kind == "string":
                    k = json.loads(k)
                elif k_kind != "ident":
                    raise ParseError(f"{self.where}:{k_line}: expected a name, found {k!r}")
                sep = self._next()[1]
                if sep not in ("=", ":"):
                    raise ParseError(f"{self.where}:{k_line}: expected '=' after {k!r}")
                obj[k] = self.value()
                if self._peek()[1] == ",":
                    self._next()
            self._expect("}")
            return obj
        raise ParseError(f"{self.where}:{line}: unexpected {v!r} (functions and references are not supported here)")

    def attributes(self):
        out = {}
        while self._peek()[0] is not None:
            _, name, line = self._next()
            self._expect("=")
            out[name] = self.value()
        return out


def read_tfvars(path):
    text = Path(path).read_text(encoding="utf-8")
    return _Parser(_tokens(text, str(path)), str(path)).attributes()


# ------------------------------------------------------------------ the checks
def main(argv):
    account = Path(argv[1]) if len(argv) > 1 else Path("accounts/dev")
    if not account.is_dir():
        print(f"error: {account} is not a folder (run this from the terraform-v2 folder)")
        return 2

    def load(stack, filename, var):
        path = account / stack / filename
        if not path.exists():
            print(f"note: {path} not found, so references to {stack} are not checked")
            return None
        try:
            return read_tfvars(path).get(var, {})
        except ParseError as e:
            print(f"error: {e}")
            sys.exit(2)

    dbs = load("databases", "databases.auto.tfvars", "databases")
    whs = load("warehouses", "warehouses.auto.tfvars", "warehouses")
    ints = load("integrations", "integrations.auto.tfvars", "storage_integrations")
    pols = load("security", "security.auto.tfvars", "network_policies")
    users = load("users", "users.auto.tfvars", "users")
    roles = load("rbac", "roles.auto.tfvars", "account_roles")
    external = []
    if (account / "rbac" / "roles.auto.tfvars").exists():
        external = read_tfvars(account / "rbac" / "roles.auto.tfvars").get("external_roles", [])

    databases = set(dbs or {})
    schemas = {f"{d}.{s}" for d, v in (dbs or {}).items() for s in (v.get("schemas") or {})}
    known_roles = set(roles or {}) | SYSTEM_ROLES | set(external)

    problems = []

    def need(kind, name, universe, where):
        if universe is None:  # that stack's file was not found; already noted
            return
        if name not in universe:
            hint = ""
            close = [u for u in universe if u.lower() == str(name).lower()]
            if close:
                hint = f" (did you mean {close[0]}? names are case-sensitive)"
            problems.append(f"{where}: {kind} {name!r} is not defined{hint}")

    # users -> warehouses, policies, databases/schemas, roles
    for uname, u in (users or {}).items():
        where = f"users/{uname}"
        if u.get("default_warehouse"):
            need("warehouse", u["default_warehouse"], set(whs) if whs is not None else None, where)
        if u.get("network_policy"):
            need("network policy", u["network_policy"], set(pols) if pols is not None else None, where)
        if u.get("default_role"):
            need("role", u["default_role"], known_roles if roles is not None else None, where)
        ns = u.get("default_namespace")
        if ns and dbs is not None:
            need("schema" if "." in ns else "database", ns, schemas if "." in ns else databases, where)

    # rbac -> users, databases, schemas, warehouses, integrations, roles
    for rname, r in (roles or {}).items():
        where = f"rbac/{rname}"
        for u in r.get("users") or []:
            need("user", u, set(users) if users is not None else None, where)
        for c in r.get("inherits") or []:
            need("role", c, known_roles, where)
        for d in (r.get("databases") or {}):
            need("database", d, databases if dbs is not None else None, where)
        for w in (r.get("warehouses") or {}):
            need("warehouse", w, set(whs) if whs is not None else None, where)
        for i in (r.get("integrations") or {}):
            need("integration", i, set(ints) if ints is not None else None, where)
        for s in (r.get("schemas") or {}):
            need("schema", s, schemas if dbs is not None else None, where)

    if problems:
        print(f"{len(problems)} name(s) do not line up:\n")
        for p in problems:
            print("  -", p)
        return 1
    print("OK: every name that one stack uses from another is defined.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
