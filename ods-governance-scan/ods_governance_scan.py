#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
 ODS Data Governance Scan - a free tool from Org Data Solutions
=============================================================================

 What it does
 ------------
 Answers the question every association, AMC and nonprofit is being asked by
 its board right now: "before we point AI at our data, do we even know what
 sensitive information is in there, and who can read it?"

 Point it at a SQL Server / Azure SQL database you own (a read-only login is
 enough) and it produces a governance-readiness report:

   1. WHAT'S IN THERE   - every table and column, with row counts.
   2. WHAT'S SENSITIVE  - columns that look like PII, credentials, payment or
                          financial data, by NAME and (with --sample) by the
                          VALUES they actually hold. The second pass is the
                          one that finds the "notes" column full of email
                          addresses.
   3. WHO CAN READ IT   - the logins and roles that can SELECT from the
                          tables holding that sensitive data.
   4. WHAT TO FIX FIRST - findings ranked by severity, plus a 0-100
                          governance-readiness score across four axes.

 Everything is READ-ONLY. The script issues SELECTs against system catalog
 views (and, with --sample, TOP-N reads of the columns it is inspecting). It
 never writes, never alters, and never sends your data anywhere - the report
 is written to disk next to the script.

 Usage
 -----
   python ods_governance_scan.py                     # scan using config.xml
   python ods_governance_scan.py --sample            # also inspect values (recommended)
   python ods_governance_scan.py --sample --rows=200 # deeper value sampling
   python ods_governance_scan.py --schemas=dbo,ops   # limit to some schemas
   python ods_governance_scan.py --out=./report      # choose an output folder

 Outputs (in --out, default: the current folder)
   governance_report.html      branded one-page summary - start here
   governance_findings.csv     one row per sensitive/at-risk column
   governance_tables.csv       table inventory with row counts + PII counts
   governance_access.csv       principals that can read sensitive tables

 Setup (one-time, ~2 minutes)
 ----------------------------
 1. pip install pyodbc            (plus a SQL Server ODBC driver - "ODBC
                                   Driver 18 for SQL Server" ships with SSMS
                                   and most Windows SQL installs)
 2. Copy config.sample.xml to config.xml next to this script and fill in your
    server, database and credentials. A read-only login (db_datareader) is
    enough, and is what we recommend. Keep config.xml out of source control.

 Questions, or want this running continuously instead of once?
 support@orgdatasolutions.com - the hosted ODS Data Management Platform does
 this every day, enforces the classifications it finds (masking sensitive
 columns for the right roles everywhere, including in AI answers), and emails
 you a weekly governance digest.

 Load these results into your free workspace (free for nonprofits and .org
 organizations): https://data.orgdatasolutions.com/signup?src=toolkit-governance-scan

 -----------------------------------------------------------------------------
 Copyright (c) 2026 Org Data Solutions. MIT License (see LICENSE): free to
 use, change and share, as-is, no warranty.
=============================================================================
"""

import argparse
import csv
import html
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timezone

TOOL_NAME = "ODS Data Governance Scan"
SUPPORT_EMAIL = "support@orgdatasolutions.com"
PLATFORM_URL = "https://data.orgdatasolutions.com"
# A plain link: it carries only the tool name, never any scan results.
SIGNUP_URL = PLATFORM_URL + "/signup?src=toolkit-governance-scan"

# --------------------------------------------------------------------------
# Detection rules
# --------------------------------------------------------------------------
# Name heuristics. Deliberately the same vocabulary the ODS platform uses, so
# a finding here maps 1:1 onto a sensitivity flag there.
NAME_RULES = [
    ("Email",              r"e[-_]?mail"),
    ("Phone",              r"phone|mobile|cell(?!ar)|fax"),
    ("SSN / Tax ID",       r"\bssn\b|social.?security|tax.?id|\bein\b|\bnin\b"),
    ("Date of Birth",      r"birth|\bdob\b"),
    ("Address",            r"address|street|address1|postal|zip.?code|\bzip\b"),
    ("Name",               r"first.?name|last.?name|full.?name|surname|given.?name|middle.?name"),
    # "hash"/"salt" alone are far too broad — content_hash, url_hash and
    # feed_hash are integrity checksums, not credentials. Only flag them when
    # paired with a credential word.
    ("Credential / Secret",
     r"password|passwd|\bpwd\b|secret|api.?key|apikey|access.?token|\btoken\b"
     r"|(password|pwd|token|secret|key|credential|auth)[._ -]?(hash|salt)"),
    ("Payment",            r"credit.?card|card.?number|\bcvv\b|\biban\b|routing|account.?number|bank"),
    ("Financial",          r"salary|compensation|wage|income|revenue.?per|donation.?amount"),
    ("Health",             r"diagnos|medical|health|allerg|disabilit|medication"),
]
NAME_RULES = [(flag, re.compile(rx, re.I)) for flag, rx in NAME_RULES]

# Shapes that are NOT personal data but look like phone numbers to a loose
# regex. Checked first so an IP address or a version string never becomes "Phone".
NOT_PII_RULES = [
    ("ip", re.compile(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$")),
    ("ip6", re.compile(r"^[0-9A-Fa-f:]{6,}:[0-9A-Fa-f:]*$")),
    ("version", re.compile(r"^\d+\.\d+(\.\d+)+$")),
    ("guid", re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")),
]

# Value heuristics (used with --sample). Order matters: first match wins.
# Phone is deliberately strict — it must carry phone punctuation or be a plain
# 10/11-digit number — because bare 9-digit ids (EINs) and dotted quads (IPs)
# otherwise swamp it with false positives.
VALUE_RULES = [
    ("Email",         re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")),
    ("SSN / Tax ID",  re.compile(r"^\d{3}-\d{2}-\d{4}$|^\d{2}-\d{7}$")),
    ("Date of Birth", re.compile(r"^(19|20)\d{2}[-/](0?[1-9]|1[0-2])[-/](0?[1-9]|[12]\d|3[01])$")),
    ("Phone",         re.compile(r"^(\+\d{1,3}[\s.-]?)?(\(\d{3}\)|\d{3})[\s.-]\d{3}[\s.-]\d{4}$|^\+?\d{10,11}$")),
]

# How serious each classification is. Value inspection may ESCALATE a column's
# classification but must never silently downgrade one the name already proved.
FLAG_SEVERITY = {
    "Credential / Secret": "high", "Payment": "high", "SSN / Tax ID": "high", "Health": "high",
    "Date of Birth": "medium", "Financial": "medium",
    "Email": "low", "Phone": "low", "Address": "low", "Name": "low",
}
# Free text that CONTAINS sensitive values (the "notes column" case).
CONTAINS_RULES = [
    ("Email", re.compile(r"[^@\s]+@[^@\s]+\.[A-Za-z]{2,}")),
    ("SSN / Tax ID", re.compile(r"\b\d{3}-\d{2}-\d{4}\b")),
]

# Columns whose names say "credential" but whose values look like plaintext.
HASH_HINTS = re.compile(r"^\$2[aby]\$|^\$argon2|^pbkdf2|^[A-Fa-f0-9]{32,}$|^[A-Za-z0-9+/]{40,}={0,2}$")

SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}


def luhn_ok(digits: str) -> bool:
    """Card-number check so we don't flag every 16-digit id as payment data."""
    d = [int(c) for c in digits if c.isdigit()]
    if len(d) < 13 or len(d) > 19:
        return False
    total, alt = 0, False
    for n in reversed(d):
        if alt:
            n *= 2
            if n > 9:
                n -= 9
        total += n
        alt = not alt
    return total % 10 == 0


# --------------------------------------------------------------------------
# Config + connection
# --------------------------------------------------------------------------
def load_config(path):
    if not os.path.exists(path):
        sys.exit(
            f"\n  Missing {os.path.basename(path)}.\n"
            f"  Copy config.sample.xml to config.xml next to this script and fill it in.\n"
        )
    root = ET.parse(path).getroot()

    def val(tag, default=""):
        el = root.find(tag)
        return (el.text or "").strip() if el is not None and el.text else default

    cfg = {
        "server": val("Server"),
        "database": val("Database"),
        "username": val("Username"),
        "password": val("Password"),
        "driver": val("Driver", "ODBC Driver 18 for SQL Server"),
        "trusted": val("TrustedConnection", "no").lower() in ("yes", "true", "1"),
        "encrypt": val("Encrypt", "yes"),
        "trust_cert": val("TrustServerCertificate", "yes"),
    }
    if not cfg["server"] or not cfg["database"]:
        sys.exit("  config.xml needs at least <Server> and <Database>.")
    return cfg


def connect(cfg):
    try:
        import pyodbc  # noqa: F401
    except ImportError:
        sys.exit(
            "\n  This tool needs the pyodbc package:\n"
            "      pip install pyodbc\n"
            "  plus a SQL Server ODBC driver (e.g. 'ODBC Driver 18 for SQL Server').\n"
        )
    import pyodbc

    parts = [
        f"DRIVER={{{cfg['driver']}}}",
        f"SERVER={cfg['server']}",
        f"DATABASE={cfg['database']}",
        f"Encrypt={cfg['encrypt']}",
        f"TrustServerCertificate={cfg['trust_cert']}",
        "Connection Timeout=30",
    ]
    if cfg["trusted"]:
        parts.append("Trusted_Connection=yes")
    else:
        parts.append(f"UID={cfg['username']}")
        parts.append(f"PWD={cfg['password']}")
    try:
        return pyodbc.connect(";".join(parts), readonly=True)
    except Exception as ex:  # noqa: BLE001 - surface the driver's own message
        sys.exit(f"\n  Could not connect: {ex}\n")


# --------------------------------------------------------------------------
# Inventory
# --------------------------------------------------------------------------
def fetch_inventory(cur, schemas):
    """Tables + columns + row counts, from the catalog views (no table scans)."""
    where = ""
    params = []
    if schemas:
        where = "AND s.name IN (" + ",".join("?" * len(schemas)) + ")"
        params = schemas

    cur.execute(f"""
        SELECT s.name AS schema_name, t.name AS table_name,
               ISNULL(p.rows, 0) AS row_count,
               CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i
                                 WHERE i.object_id = t.object_id AND i.is_primary_key = 1)
                    THEN 1 ELSE 0 END AS has_pk
        FROM sys.tables t
        JOIN sys.schemas s ON s.schema_id = t.schema_id
        OUTER APPLY (SELECT TOP (1) SUM(p2.rows) AS rows
                     FROM sys.partitions p2
                     WHERE p2.object_id = t.object_id AND p2.index_id IN (0,1)) p
        WHERE t.is_ms_shipped = 0 {where}
        ORDER BY s.name, t.name;
    """, params)
    tables = [
        {"schema": r[0], "table": r[1], "rows": int(r[2] or 0), "has_pk": bool(r[3]), "columns": []}
        for r in cur.fetchall()
    ]

    cur.execute(f"""
        SELECT s.name, t.name, c.name, ty.name AS data_type, c.max_length, c.is_nullable
        FROM sys.columns c
        JOIN sys.tables t ON t.object_id = c.object_id
        JOIN sys.schemas s ON s.schema_id = t.schema_id
        JOIN sys.types ty ON ty.user_type_id = c.user_type_id
        WHERE t.is_ms_shipped = 0 {where}
        ORDER BY s.name, t.name, c.column_id;
    """, params)
    by_table = defaultdict(list)
    for schema, table, col, dtype, maxlen, nullable in cur.fetchall():
        by_table[(schema, table)].append(
            {"name": col, "type": dtype, "max_length": maxlen, "nullable": bool(nullable)}
        )
    for t in tables:
        t["columns"] = by_table.get((t["schema"], t["table"]), [])
    return tables


def fetch_readers(cur):
    """Principals that can read data: db_datareader members, db_owner, and
    explicit SELECT grants. This is the 'who can see it' half of governance."""
    readers = []
    try:
        cur.execute("""
            SELECT r.name AS role_name, m.name AS member_name, m.type_desc
            FROM sys.database_role_members drm
            JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
            JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
            WHERE r.name IN ('db_datareader','db_owner','db_ddladmin')
              AND m.name NOT IN ('dbo','public');
        """)
        for role, member, kind in cur.fetchall():
            readers.append({"principal": member, "kind": kind, "grant": f"member of {role}", "object": "(whole database)"})
    except Exception:  # noqa: BLE001 - permission to read catalog may be limited
        pass

    try:
        cur.execute("""
            SELECT p.name, p.type_desc, dp.permission_name,
                   ISNULL(s.name + '.' + o.name, '(database)') AS obj
            FROM sys.database_permissions dp
            JOIN sys.database_principals p ON p.principal_id = dp.grantee_principal_id
            LEFT JOIN sys.objects o ON o.object_id = dp.major_id AND dp.class = 1
            LEFT JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE dp.permission_name IN ('SELECT','CONTROL','VIEW DEFINITION')
              AND dp.state_desc = 'GRANT'
              AND p.name NOT IN ('public','dbo');
        """)
        for name, kind, perm, obj in cur.fetchall():
            readers.append({"principal": name, "kind": kind, "grant": perm, "object": obj})
    except Exception:  # noqa: BLE001
        pass
    return readers


# --------------------------------------------------------------------------
# Detection
# --------------------------------------------------------------------------
def classify_by_name(column_name):
    for flag, rx in NAME_RULES:
        if rx.search(column_name):
            return flag
    return None


def sample_values(cur, schema, table, column, rows):
    """TOP-N non-null values for one column. Read-only, capped, best-effort."""
    try:
        cur.execute(
            f"SELECT TOP ({int(rows)}) CAST([{column}] AS NVARCHAR(400)) "
            f"FROM [{schema}].[{table}] WITH (NOLOCK) "
            f"WHERE [{column}] IS NOT NULL"
        )
        return [r[0] for r in cur.fetchall() if r[0] is not None]
    except Exception:  # noqa: BLE001 - unreadable column: skip silently
        return []


def classify_by_values(values):
    """(flag, confidence, note) from sampled values, or None."""
    if not values:
        return None
    clean = [v.strip() for v in values if v and v.strip()]
    if not clean:
        return None
    n = len(clean)

    # Bail out on shapes that merely resemble PII (IPs, GUIDs, versions).
    for _, rx in NOT_PII_RULES:
        if sum(1 for v in clean if rx.match(v)) / n >= 0.6:
            return None

    for flag, rx in VALUE_RULES:
        hits = sum(1 for v in clean if rx.match(v))
        if hits / n >= 0.6:
            return (flag, round(hits / n, 2), f"{hits}/{n} sampled values match this shape")

    digits_only = [re.sub(r"\D", "", v) for v in clean]
    card_hits = sum(1 for d in digits_only if luhn_ok(d))
    if card_hits / n >= 0.5:
        return ("Payment", round(card_hits / n, 2), f"{card_hits}/{n} sampled values pass a card checksum")

    for flag, rx in CONTAINS_RULES:
        hits = sum(1 for v in clean if rx.search(v))
        if hits / n >= 0.3:
            return (flag, round(hits / n, 2), f"{hits}/{n} sampled values CONTAIN this inside free text")
    return None


def looks_plaintext_secret(values):
    if not values:
        return False
    clean = [v.strip() for v in values if v and v.strip()]
    if not clean:
        return False
    hashed = sum(1 for v in clean if HASH_HINTS.match(v))
    return (hashed / len(clean)) < 0.2


# --------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------
def scan(cur, tables, do_sample, sample_rows):
    findings = []
    for t in tables:
        for c in t["columns"]:
            name_flag = classify_by_name(c["name"])
            value_flag = conf = note = None
            secret_plaintext = False

            textish = c["type"].lower() in (
                "varchar", "nvarchar", "char", "nchar", "text", "ntext", "sql_variant"
            )
            # Sample when the name says something, or when it's free text wide
            # enough to hide PII (the case name rules structurally cannot catch).
            worth_sampling = do_sample and t["rows"] > 0 and (
                name_flag is not None or (textish and (c["max_length"] in (-1,) or c["max_length"] >= 40))
            )
            if worth_sampling:
                vals = sample_values(cur, t["schema"], t["table"], c["name"], sample_rows)
                verdict = classify_by_values(vals)
                if verdict:
                    value_flag, conf, note = verdict
                if name_flag == "Credential / Secret" and vals:
                    secret_plaintext = looks_plaintext_secret(vals)

            # Precedence: values may ESCALATE (or reveal what the name hides),
            # never quietly downgrade a classification the name already proved.
            rank = {"high": 3, "medium": 2, "low": 1}
            flag = name_flag
            if value_flag and (
                name_flag is None
                or rank.get(FLAG_SEVERITY.get(value_flag, "low"), 1)
                   > rank.get(FLAG_SEVERITY.get(name_flag, "low"), 1)
            ):
                flag = value_flag
            if not flag and not secret_plaintext:
                continue

            if secret_plaintext:
                severity = "critical"
                why = "Credential-style column whose sampled values do not look hashed."
            else:
                severity = FLAG_SEVERITY.get(flag, "low")
                # Confirmed by real values, a low-severity hit still deserves
                # more attention than a guess from a column name.
                if severity == "low" and value_flag:
                    severity = "medium"
                why = {"high": "Regulated / high-impact data.",
                       "medium": "Sensitive personal data."}.get(severity, "Personal data.")

            evidence = note or ("column name" if name_flag else "")
            if value_flag and name_flag and value_flag != name_flag:
                evidence += (f" — values look like {value_flag}" if flag == name_flag
                             else f" (name suggested {name_flag})")
            elif value_flag and not name_flag:
                evidence += " - the column NAME gives no hint"

            findings.append({
                "schema": t["schema"], "table": t["table"], "column": c["name"],
                "type": c["type"], "rows": t["rows"], "flag": flag or "Credential / Secret",
                "severity": severity, "detected_by": "values" if value_flag or secret_plaintext else "name",
                "confidence": conf if conf is not None else ("" if value_flag else 0.5),
                "evidence": evidence.strip(), "why": why,
            })
    findings.sort(key=lambda f: (SEVERITY_ORDER[f["severity"]], -f["rows"], f["table"]))
    return findings


def score(tables, findings, readers, did_sample):
    """Four 0-100 axes plus an overall. Deliberately conservative: an
    unsampled scan is capped, because names alone can't prove coverage."""
    total_cols = sum(len(t["columns"]) for t in tables) or 1
    sensitive = [f for f in findings if f["flag"] != "Credential / Secret" or f["severity"] != "critical"]
    critical = [f for f in findings if f["severity"] == "critical"]
    high = [f for f in findings if f["severity"] == "high"]
    value_found = [f for f in findings if f["detected_by"] == "values"]

    discovery = 100 if did_sample else 55
    if did_sample and value_found:
        discovery = 100

    exposure = 100
    exposure -= min(60, len(critical) * 30)
    exposure -= min(30, len(high) * 3)

    breadth = 100
    broad_readers = [r for r in readers if r["object"] == "(whole database)"]
    breadth -= min(60, len(broad_readers) * 10)
    if sensitive and broad_readers:
        breadth -= 10

    hygiene = 100
    no_pk = [t for t in tables if not t["has_pk"] and t["rows"] > 0]
    empty = [t for t in tables if t["rows"] == 0]
    hygiene -= min(30, len(no_pk) * 3)
    hygiene -= min(20, int(len(empty) / max(1, len(tables)) * 40))

    axes = {
        "Sensitive-data discovery": max(0, min(100, discovery)),
        "Credential & regulated-data exposure": max(0, min(100, exposure)),
        "Access breadth": max(0, min(100, breadth)),
        "Schema hygiene": max(0, min(100, hygiene)),
    }
    overall = int(round(sum(axes.values()) / len(axes)))
    return overall, axes, {
        "total_columns": total_cols, "critical": len(critical), "high": len(high),
        "value_only": len([f for f in value_found if f["detected_by"] == "values"]),
        "no_pk": len(no_pk), "empty": len(empty), "broad_readers": len(broad_readers),
    }


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
def write_csv(path, rows, headers):
    with open(path, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=headers, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def band(v):
    return "good" if v >= 80 else ("warn" if v >= 55 else "bad")


def write_report(path, cfg, tables, findings, readers, overall, axes, stats, did_sample):
    e = html.escape
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    by_flag = defaultdict(int)
    for f in findings:
        by_flag[f["flag"]] += 1
    top_tables = sorted(
        {(f["schema"], f["table"]) for f in findings},
        key=lambda st: -sum(1 for f in findings if (f["schema"], f["table"]) == st),
    )[:10]

    rows_html = []
    for f in findings[:200]:
        rows_html.append(
            f"<tr class='sev-{f['severity']}'><td>{e(f['severity'])}</td>"
            f"<td>{e(f['schema'])}.{e(f['table'])}</td><td class='mono'>{e(f['column'])}</td>"
            f"<td>{e(f['flag'])}</td><td>{e(str(f['detected_by']))}</td>"
            f"<td>{e(str(f['evidence']))}</td><td class='num'>{f['rows']:,}</td></tr>"
        )

    axes_html = "".join(
        f"<div class='axis'><div class='axis-label'>{e(k)}</div>"
        f"<div class='bar'><span class='{band(v)}' style='width:{v}%'></span></div>"
        f"<div class='axis-val'>{v}</div></div>"
        for k, v in axes.items()
    )
    flags_html = "".join(
        f"<li><b>{c}</b> &times; {e(k)}</li>" for k, c in sorted(by_flag.items(), key=lambda kv: -kv[1])
    ) or "<li>None detected.</li>"
    tables_html = "".join(
        f"<li>{e(s)}.{e(t)} &mdash; "
        f"{sum(1 for f in findings if (f['schema'], f['table']) == (s, t))} flagged column(s)</li>"
        for s, t in top_tables
    ) or "<li>None.</li>"
    readers_html = "".join(
        f"<li class='mono'>{e(r['principal'])} <span class='muted'>&mdash; {e(r['grant'])}</span></li>"
        for r in readers[:15]
    ) or "<li>No non-default readers found (or the login can't read permission metadata).</li>"

    sample_note = (
        "Values were sampled, so columns whose <em>names</em> reveal nothing were still inspected."
        if did_sample else
        "<b>Names only.</b> Re-run with <span class='mono'>--sample</span> to inspect actual values &mdash; "
        "that pass finds sensitive data hiding in generically-named columns, and is the difference between "
        "a guess and an inventory."
    )

    doc = f"""<!doctype html><html><head><meta charset="utf-8">
<title>Data Governance Scan &mdash; {e(cfg['database'])}</title>
<style>
 body{{font-family:Segoe UI,Arial,sans-serif;color:#1e293b;margin:0;background:#f8fafc}}
 .wrap{{max-width:60rem;margin:0 auto;padding:2rem}}
 header{{background:#0f172a;color:#fff;padding:1.5rem 2rem}}
 header h1{{margin:0;font-size:1.35rem}} header p{{margin:.35rem 0 0;color:#94a3b8;font-size:.85rem}}
 .card{{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:1.1rem 1.25rem;margin:1rem 0}}
 h2{{font-size:1rem;margin:0 0 .6rem;border-bottom:1px solid #e2e8f0;padding-bottom:.35rem}}
 .score{{display:flex;align-items:center;gap:1.5rem;flex-wrap:wrap}}
 .big{{font-size:3rem;font-weight:700;line-height:1}}
 .good{{color:#16a34a;background:#16a34a}} .warn{{color:#d97706;background:#d97706}} .bad{{color:#dc2626;background:#dc2626}}
 .axis{{display:grid;grid-template-columns:16rem 1fr 2.5rem;gap:.6rem;align-items:center;margin:.3rem 0;font-size:.85rem}}
 .bar{{background:#e2e8f0;border-radius:99px;height:.5rem;overflow:hidden}}
 .bar span{{display:block;height:100%}}
 .axis-val{{text-align:right;font-weight:600}}
 table{{border-collapse:collapse;width:100%;font-size:.78rem}}
 th,td{{border:1px solid #e2e8f0;padding:.3rem .5rem;text-align:left;vertical-align:top}}
 th{{background:#f1f5f9}} .num{{text-align:right}} .mono{{font-family:Consolas,monospace}}
 .muted{{color:#64748b}} ul{{margin:.3rem 0;padding-left:1.1rem;font-size:.85rem}}
 .sev-critical td:first-child{{color:#dc2626;font-weight:700}}
 .sev-high td:first-child{{color:#ea580c;font-weight:600}}
 .sev-medium td:first-child{{color:#d97706}} .sev-low td:first-child{{color:#64748b}}
 .cta{{background:#eef2ff;border-color:#c7d2fe}} .cta a{{color:#4338ca}}
 .grid2{{display:grid;grid-template-columns:1fr 1fr;gap:1rem}}
 @media(max-width:720px){{.grid2{{grid-template-columns:1fr}}.axis{{grid-template-columns:1fr}}}}
</style></head><body>
<header><h1>Data Governance Scan</h1>
<p>{e(cfg['database'])} on {e(cfg['server'])} &middot; generated {generated} &middot; {TOOL_NAME}</p></header>
<div class="wrap">

<div class="card"><div class="score">
  <div><div class="big {band(overall)}" style="background:none">{overall}</div>
       <div class="muted" style="font-size:.8rem">of 100</div></div>
  <div style="flex:1;min-width:20rem">{axes_html}</div>
</div>
<p class="muted" style="font-size:.85rem;margin:.8rem 0 0">
Scanned <b>{len(tables):,}</b> tables / <b>{stats['total_columns']:,}</b> columns and flagged
<b>{len(findings):,}</b> column(s): <b>{stats['critical']}</b> critical, <b>{stats['high']}</b> high.
{sample_note}</p></div>

<div class="grid2">
  <div class="card"><h2>What was found</h2><ul>{flags_html}</ul></div>
  <div class="card"><h2>Most affected tables</h2><ul>{tables_html}</ul></div>
</div>

<div class="card"><h2>Who can read this database</h2>
<ul>{readers_html}</ul>
<p class="muted" style="font-size:.8rem">Every principal above can read the sensitive columns listed below,
unless column-level permissions say otherwise. Broad membership (db_datareader / db_owner) is the usual
reason a governance review fails.</p></div>

<div class="card"><h2>Findings &mdash; fix from the top</h2>
<table><thead><tr><th>Severity</th><th>Table</th><th>Column</th><th>Classification</th>
<th>Detected by</th><th>Evidence</th><th class="num">Rows</th></tr></thead>
<tbody>{''.join(rows_html) or '<tr><td colspan="7">Nothing flagged.</td></tr>'}</tbody></table>
<p class="muted" style="font-size:.8rem">Showing the first 200; the full list is in
<span class="mono">governance_findings.csv</span>.</p></div>

<div class="card cta"><h2>What to do with this</h2>
<p style="font-size:.9rem">This is a point-in-time snapshot from one scan. Governance is a
standing process: data changes, columns get added, and people join and leave. The hosted
<b>ODS Data Management Platform</b> turns this report into something that runs by itself:</p>
<ul>
 <li><b>Classify once, enforce everywhere</b> &mdash; tag a column sensitive and it is masked or blocked
     per role in every grid, chart, export, share link, <em>and AI answer</em>.</li>
 <li><b>AI-assisted discovery</b> &mdash; the same value-based inspection you just ran, continuously,
     with one-click accept into enforced policy.</li>
 <li><b>Proof on demand</b> &mdash; a governance scorecard with trend, a full access audit, and an
     exportable evidence pack for your auditor or board.</li>
 <li><b>Weekly digest</b> &mdash; what changed, what's newly unclassified, who was blocked.</li>
</ul>
<p style="font-size:.9rem">Ask us for a walkthrough on your own data:
<a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a> &middot;
<a href="{PLATFORM_URL}">{PLATFORM_URL}</a></p>
<p style="font-size:.9rem;margin-bottom:0">Free for nonprofits and .org organizations:
<a href="{SIGNUP_URL}"><b>Load these results into your free workspace</b></a></p></div>

<p class="muted" style="font-size:.75rem;text-align:center">
{TOOL_NAME} &mdash; free from Org Data Solutions. Read-only: this tool never writes to your database
and never transmits your data anywhere.</p>
</div></body></html>"""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(doc)


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=TOOL_NAME, add_help=True)
    ap.add_argument("--config", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.xml"))
    ap.add_argument("--out", default=".", help="output folder (default: current)")
    ap.add_argument("--sample", action="store_true", help="also inspect column VALUES (recommended)")
    ap.add_argument("--rows", type=int, default=50, help="values sampled per column with --sample (default 50)")
    ap.add_argument("--schemas", default="", help="comma-separated schemas to include (default: all)")
    args = ap.parse_args()

    cfg = load_config(args.config)
    schemas = [s.strip() for s in args.schemas.split(",") if s.strip()]
    os.makedirs(args.out, exist_ok=True)

    print(f"\n{TOOL_NAME}")
    print(f"  Connecting to {cfg['database']} on {cfg['server']} ...")
    conn = connect(cfg)
    cur = conn.cursor()

    print("  Reading catalog ...")
    tables = fetch_inventory(cur, schemas)
    print(f"    {len(tables):,} tables, {sum(len(t['columns']) for t in tables):,} columns")

    print("  Checking who can read it ...")
    readers = fetch_readers(cur)

    print("  Classifying columns" + (" (sampling values - this is the slow part) ..." if args.sample else " by name ..."))
    findings = scan(cur, tables, args.sample, args.rows)
    overall, axes, stats = score(tables, findings, readers, args.sample)

    write_csv(os.path.join(args.out, "governance_findings.csv"), findings,
              ["severity", "schema", "table", "column", "type", "flag", "detected_by",
               "confidence", "evidence", "why", "rows"])
    write_csv(os.path.join(args.out, "governance_tables.csv"),
              [{"schema": t["schema"], "table": t["table"], "rows": t["rows"],
                "columns": len(t["columns"]), "has_primary_key": t["has_pk"],
                "flagged_columns": sum(1 for f in findings
                                       if f["schema"] == t["schema"] and f["table"] == t["table"])}
               for t in tables],
              ["schema", "table", "rows", "columns", "has_primary_key", "flagged_columns"])
    write_csv(os.path.join(args.out, "governance_access.csv"), readers,
              ["principal", "kind", "grant", "object"])
    report = os.path.join(args.out, "governance_report.html")
    write_report(report, cfg, tables, findings, readers, overall, axes, stats, args.sample)

    conn.close()
    print(f"\n  Governance readiness: {overall}/100")
    print(f"    {stats['critical']} critical, {stats['high']} high-severity finding(s)")
    if not args.sample:
        print("    (names only - re-run with --sample to inspect values)")
    print(f"\n  Open the report:  {os.path.abspath(report)}")
    print(f"  Load these results into your free workspace: {SIGNUP_URL}\n")


if __name__ == "__main__":
    main()
