#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
 ODS Dataverse Audit Export - a free tool from Org Data Solutions
=============================================================================

 What it does
 ------------
 Answers two questions every Dataverse / Dynamics 365 / Power Platform admin
 (including teams on association-management systems built on Dataverse)
 eventually asks:

   1. "Is auditing actually turned on, and for which tables and columns?"
   2. "How do I get my audit history OUT of Dataverse?"

 Microsoft provides no bulk export from the audit views - the data is only
 reachable through the Web API. This script does it for you, with nothing but
 a stock Python 3.9+ install (standard library only; no packages to install).

 Two modes:

   python ods_audit_export.py explore
       Audit-readiness check. Writes:
         audit_environment.csv        org-level settings (on/off, retention,
                                      user-access auditing, earliest event)
         audit_coverage.csv           one row per table: auditing on/off,
                                      whether a managed solution locks it
       Add --columns to also write:
         audit_coverage_columns.csv   one row per column of every audited
                                      table (slower: one API call per table)

   python ods_audit_export.py export
       Exports audit events to ONE CSV PER TABLE (audit_contact.csv,
       audit_account.csv, ...) - one row per changed field, with old and new
       values, who made the change, the calling (impersonating) user, and the
       transaction id that groups multi-field saves.
         --days=30                window to export (default: last 30 days)
         --since=2026-01-01       or an explicit start date (overrides --days)
         --tables=contact,account limit to specific tables (logical names)
         --details                also call RetrieveAuditDetails for events
                                  whose old/new values aren't in the audit row
                                  itself (slower: one API call per event)
         --detail-cap=500         cap on those per-event calls (default 500)

 Both modes also (re)generate audit_report.html in the output folder - a
 branded, shareable one-page summary (highlights, coverage, top tables and
 users) that links back to the CSVs for the full row-level detail. Run
 explore then export and the page accumulates both.

 CSV was chosen over JSON deliberately: it streams row-by-row (no memory
 blow-ups on large histories), splits naturally per table, and your
 membership team can open it straight in Excel.

 Setup (one-time, ~10 minutes)
 -----------------------------
 1. Create an app registration in Microsoft Entra ID and give it a client
    secret ("server-to-server" / client-credentials access).
 2. In Power Platform admin center, add it as an Application User on your
    environment with a security role that can read audit data (System
    Administrator covers it).
 3. Copy config.sample.xml to config.xml next to this script and fill in
    your environment URL, tenant id, client id, and client secret.
    (Keep config.xml out of source control - it holds a secret.)

 If auditing turns out to be OFF (mode 1 will tell you), turn it on in
 Power Platform admin center -> Environment -> Settings -> Audit settings,
 and per-table under Tables -> <table> -> Properties -> Audit changes to its data.
 Auditing only records changes made AFTER it is enabled.

 -----------------------------------------------------------------------------
 Copyright (c) 2026 Org Data Solutions. MIT License (see LICENSE): free to
 use, change and share, as-is, no warranty.

 It exports snapshots. If you'd rather have your audit history continuously
 mirrored into a managed warehouse - with searchable activity reports,
 before/after drill-through, staff stewardship summaries, high-risk change
 alerts, and a weekly email digest for your executives - that's exactly what
 our hosted Audit Analyzer does, and we run it for you.

   Org Data Solutions - John Stover
   support@orgdatasolutions.com
   https://orgdatasolutions.com

 Load these results into your free workspace (free for nonprofits and .org
 organizations): https://data.orgdatasolutions.com/signup?src=toolkit-audit-export
 -----------------------------------------------------------------------------
"""
from __future__ import annotations

import csv
import datetime
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ============================================================================
# CONFIGURATION - edit these two lines if your files live elsewhere
# ============================================================================
CONFIG_XML = "config.xml"        # path to your connection config (see below)
OUTPUT_DIR = "audit-export"      # folder for the CSV output (created if absent)

# config.xml format (see config.sample.xml):
#   <config>
#     <OrgUrl>https://yourorg.crm.dynamics.com</OrgUrl>
#     <TenantId>00000000-0000-0000-0000-000000000000</TenantId>
#     <ClientId>00000000-0000-0000-0000-000000000000</ClientId>
#     <ClientSecret>your-app-registration-secret</ClientSecret>
#   </config>
# ============================================================================

FV = "OData.Community.Display.V1.FormattedValue"   # display-label annotation
PAGE = 5000                                        # OData page size
# A plain link: it carries only the tool name, never any audit data.
SIGNUP_URL = "https://data.orgdatasolutions.com/signup?src=toolkit-audit-export"


# ----------------------------------------------------------------------------
# Dataverse Web API plumbing (client-credentials OAuth, paging, 429 retry)
# ----------------------------------------------------------------------------
def load_config(path: str):
    try:
        cfg = open(path, encoding="utf-8").read()
    except OSError as e:
        sys.exit(f"Could not read config file '{path}': {e}\n"
                 "Copy config.sample.xml to config.xml and fill it in "
                 "(see the setup notes at the top of this script).")
    def x(tag):
        m = re.search(f"<{tag}>(.*?)</{tag}>", cfg, re.S)
        if not m or not m.group(1).strip():
            sys.exit(f"Config file '{path}' is missing <{tag}>.")
        return m.group(1).strip()
    return x("OrgUrl").rstrip("/"), x("TenantId"), x("ClientId"), x("ClientSecret")


def get_token(org, tenant, client_id, secret):
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials", "client_id": client_id,
        "client_secret": secret, "scope": org + "/.default",
    }).encode()
    url = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"
    try:
        return json.load(urllib.request.urlopen(
            urllib.request.Request(url, data=body), timeout=30))["access_token"]
    except urllib.error.HTTPError as e:
        sys.exit(f"Sign-in failed (HTTP {e.code}). Check TenantId / ClientId / "
                 f"ClientSecret in {CONFIG_XML}.\n{e.read().decode(errors='replace')[:400]}")


def api_get(org, token, url, prefer=None):
    """One GET against the Web API, with throttling (429/503) retries."""
    full = url if url.startswith("http") else org + "/api/data/v9.2/" + url
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json",
               "OData-MaxVersion": "4.0", "OData-Version": "4.0"}
    if prefer:
        headers["Prefer"] = prefer
    req = urllib.request.Request(full.replace(" ", "%20"), headers=headers)
    for attempt in range(6):
        try:
            return json.load(urllib.request.urlopen(req, timeout=300))
        except urllib.error.HTTPError as e:
            if e.code in (429, 503) and attempt < 5:   # service protection limits
                wait = int(e.headers.get("Retry-After") or 15)
                print(f"  (throttled, waiting {wait}s...)", flush=True)
                time.sleep(wait)
                continue
            raise
    raise RuntimeError("unreachable")


def api_pages(org, token, url):
    """Yield rows across @odata.nextLink pages, with display-label annotations."""
    prefer = f'odata.maxpagesize={PAGE},odata.include-annotations="{FV}"'
    while url:
        data = api_get(org, token, url, prefer)
        yield from data.get("value", [])
        url = data.get("@odata.nextLink")


def fv(record, field):
    """Display label (formatted value) for a field, when Dataverse provides one."""
    return record.get(f"{field}@{FV}")


def label(display):
    """EntityDefinitions DisplayName -> plain text."""
    try:
        return (display or {}).get("UserLocalizedLabel", {}).get("Label") or ""
    except AttributeError:
        return ""


def open_csv(path, header):
    """utf-8-sig so the files open cleanly in Excel."""
    import os
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    f = open(path, "w", newline="", encoding="utf-8-sig")
    w = csv.writer(f)
    w.writerow(header)
    return f, w


# ----------------------------------------------------------------------------
# Branded HTML report (audit_report.html) - regenerated after every run.
# Explore and export each save their summary into _report_data.json, so
# running both accumulates into one page.
# ----------------------------------------------------------------------------
def esc(v):
    return (str("" if v is None else v).replace("&", "&amp;")
            .replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;"))


def update_report(org, section, payload):
    import os
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    data_path = os.path.join(OUTPUT_DIR, "_report_data.json")
    data = {}
    if os.path.exists(data_path):
        try:
            data = json.load(open(data_path, encoding="utf-8"))
        except ValueError:
            data = {}
    data["org"] = org
    data["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    data[section] = payload
    with open(data_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    html_path = os.path.join(OUTPUT_DIR, "audit_report.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(render_report(data))
    return html_path


REPORT_CSS = """
  :root { --ink:#111827; --muted:#6b7280; --edge:#e5e7eb; --brand:#4f46e5; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:'Segoe UI',system-ui,Arial,sans-serif; color:var(--ink);
         background:#f3f4f6; }
  header { background:#0f172a; color:#fff; padding:22px 28px; border-bottom:4px solid var(--brand); }
  .wordmark { font-size:12px; letter-spacing:.35em; color:#c7d2fe; font-weight:600; }
  .hd-title { font-size:26px; font-weight:700; margin-top:6px; }
  .meta { max-width:1020px; margin:14px auto 0; padding:0 20px; color:var(--muted); font-size:13px; }
  main { max-width:1020px; margin:0 auto; padding:8px 20px 30px; }
  h2 { font-size:16px; margin:26px 0 10px; }
  .tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; margin-top:14px; }
  .tile { background:#fff; border:1px solid var(--edge); border-radius:10px; padding:12px 14px; }
  .tile-v { font-size:22px; font-weight:700; }
  .tile-l { font-size:11px; color:var(--muted); margin-top:2px; }
  .card { background:#fff; border:1px solid var(--edge); border-radius:10px; padding:14px 16px; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th { text-align:left; color:var(--muted); font-size:11px; text-transform:uppercase;
       letter-spacing:.05em; padding:6px 8px; border-bottom:1px solid var(--edge); }
  td { padding:6px 8px; border-bottom:1px solid #f1f5f9; }
  tr:last-child td { border-bottom:none; }
  .num { text-align:right; font-variant-numeric:tabular-nums; }
  .scroll { max-height:420px; overflow:auto; }
  .pill { display:inline-block; font-size:10px; padding:1px 7px; border-radius:999px;
          background:#eef2ff; color:var(--brand); font-weight:600; }
  .pill.red { background:#fef2f2; color:#dc2626; }
  .note { color:var(--muted); font-size:12px; margin-top:8px; }
  .upsell { background:linear-gradient(120deg,#312e81,#4f46e5); color:#fff; border-radius:12px;
            padding:20px 24px; margin-top:30px; }
  .upsell h2 { margin:0 0 8px; font-size:18px; }
  .upsell p { margin:4px 0; font-size:13px; color:#e0e7ff; }
  .upsell a.btn { display:inline-block; margin-top:12px; background:#fff; color:#312e81;
                  font-weight:700; font-size:13px; text-decoration:none; padding:9px 18px; border-radius:8px; }
  footer { max-width:1020px; margin:0 auto; padding:16px 20px 34px; color:var(--muted); font-size:12px; }
  footer a { color:var(--brand); }
"""


def render_report(data):
    ex = data.get("explore") or {}
    xp = data.get("export") or {}
    tone_color = {"ok": "#16a34a", "warn": "#d97706", "bad": "#dc2626", "info": "#111827"}

    def tile(label_txt, value, tone="info"):
        return (f'<div class="tile"><div class="tile-v" style="color:{tone_color[tone]}">'
                f'{esc(value)}</div><div class="tile-l">{esc(label_txt)}</div></div>')

    def retention_tone(ret):
        if ret == "Forever":
            return "ok"
        m = re.match(r"(\d+) days", ret or "")
        if not m:
            return "warn"
        return "ok" if int(m.group(1)) >= 365 else "warn"

    tiles = []
    if ex:
        tiles.append(tile("Environment auditing", "Enabled" if ex.get("audit_on") else "DISABLED",
                          "ok" if ex.get("audit_on") else "bad"))
        ret = ex.get("retention") or "Unknown"
        tiles.append(tile("Retention", ret, retention_tone(ret)))
        tiles.append(tile("Audited tables", f"{ex.get('tables_audited', 0)} of {ex.get('tables_total', 0)}"))
        if ex.get("earliest"):
            tiles.append(tile("History since", ex["earliest"]))
        if ex.get("total_hint") and ex["total_hint"] not in ("0", "n/a"):
            tiles.append(tile("Audit events in CRM", f"{int(ex['total_hint']):,}"))
    if xp:
        tiles.append(tile(f"Events since {xp.get('since', '')}", f"{xp.get('events', 0):,}"))
        tiles.append(tile("Field changes captured", f"{xp.get('rows', 0):,}"))
        deletes = (xp.get("ops") or {}).get("Delete", 0)
        tiles.append(tile("Deletes", f"{deletes:,}", "bad" if deletes else "ok"))
        tiles.append(tile("Active users", f"{xp.get('user_count') or len(xp.get('users') or []):,}"))

    parts = [
        "<!doctype html><html><head><meta charset='utf-8'>",
        "<meta name='viewport' content='width=device-width,initial-scale=1'>",
        "<title>Dataverse Audit Report - Org Data Solutions</title>",
        f"<style>{REPORT_CSS}</style></head><body>",
        "<header><div class='wordmark'>ORG DATA SOLUTIONS</div>",
        "<div class='hd-title'>Dataverse Audit Report</div></header>",
        f"<div class='meta'>Environment: <strong>{esc(data.get('org', ''))}</strong>"
        f" &middot; Generated {esc(data.get('generated', ''))}"
        " &middot; produced by the free ODS Dataverse Audit Export tool</div>",
        "<main>",
        f"<div class='tiles'>{''.join(tiles)}</div>",
    ]

    if ex:
        parts.append("<h2>Audit coverage</h2><div class='card'>")
        ua = "Enabled" if ex.get("user_access") else "Disabled"
        locked = ex.get("locked_count", 0)
        parts.append(f"<div class='note' style='margin:0 0 10px'>User-access (login) auditing: {ua}"
                     + (f" &middot; {locked} audited table(s) locked by a managed solution" if locked else "")
                     + (" &middot; column-level detail in audit_coverage_columns.csv"
                        if ex.get("columns_included") else "") + "</div>")
        rows = "".join(
            f"<tr><td>{esc(t[1]) or esc(t[0])} <span style='color:#9ca3af'>({esc(t[0])})</span></td>"
            f"<td>{'<span class=pill>managed lock</span>' if t[2] else ''}</td></tr>"
            for t in (ex.get("audited_tables") or []))
        parts.append(f"<div class='scroll'><table><tr><th>Audited table</th><th></th></tr>{rows}</table></div>")
        parts.append("<div class='note'>Every table (including the not-audited ones) is in audit_coverage.csv.</div></div>")

    if xp:
        ops = xp.get("ops") or {}
        ops_html = "".join(f"<tr><td>{esc(k)}</td><td class='num'>{v:,}</td></tr>"
                           for k, v in sorted(ops.items(), key=lambda kv: -kv[1]))
        def del_cell(n):
            return f"<span class='pill red'>{n:,}</span>" if n else "0"
        tables = (xp.get("tables") or [])[:25]
        tbl_html = "".join(
            f"<tr><td>{esc(t[1]) or esc(t[0])} <span style='color:#9ca3af'>({esc(t[0])})</span></td>"
            f"<td class='num'>{t[2]:,}</td><td class='num'>{t[3]:,}</td>"
            f"<td class='num'>{del_cell(t[4])}</td></tr>"
            for t in tables)
        more = len(xp.get("tables") or []) - len(tables)
        users = (xp.get("users") or [])[:15]
        usr_html = "".join(
            f"<tr><td>{esc(u[0])}</td><td class='num'>{u[1]:,}</td>"
            f"<td class='num'>{u[2]:,}</td></tr>" for u in users)
        parts.append(
            "<h2>Activity highlights</h2>"
            "<div style='display:grid;grid-template-columns:1fr 2fr;gap:12px;align-items:start'>"
            f"<div class='card'><table><tr><th>Action</th><th class='num'>Events</th></tr>{ops_html}</table></div>"
            "<div class='card'><table><tr><th>Most-changed table</th><th class='num'>Events</th>"
            f"<th class='num'>Field rows</th><th class='num'>Deletes</th></tr>{tbl_html}</table>"
            + (f"<div class='note'>...and {more} more table(s) - see the per-table CSV files.</div>" if more > 0 else "")
            + "</div></div>"
            "<h2>Most active users</h2><div class='card'>"
            f"<table><tr><th>User</th><th class='num'>Events</th><th class='num'>Deletes</th></tr>{usr_html}</table>"
            "<div class='note'>Full field-by-field before/after detail is in the audit_&lt;table&gt;.csv files "
            "next to this page.</div></div>")
        if xp.get("want_details") and xp.get("detail_used", 0) >= xp.get("detail_cap", 0) > 0:
            parts.append("<div class='note'>Note: the RetrieveAuditDetails cap was reached - some events "
                         "show without field values. Re-run with a higher --detail-cap to fetch them.</div>")

    parts.extend((
        "<div class='upsell'><h2>This is a snapshot. Your audit trail isn't.</h2>"
        "<p>Dataverse purges audit history at the end of its retention window, and re-running exports "
        "by hand doesn't scale. Org Data Solutions will host and manage this for you:</p>"
        "<p>&bull; nightly mirror of your audit history into a managed warehouse (kept beyond CRM retention)"
        "<br>&bull; searchable activity reports with before/after drill-through"
        "<br>&bull; staff stewardship summaries and high-risk change alerts (deletes, merges, security roles)"
        "<br>&bull; a weekly digest email for your executives</p>"
        "<p>The ODS Data Management Platform's governance tools are free for approved nonprofits and "
        ".org organizations; the Dataverse connector is a premium add-on.</p>"
        f"<a class='btn' href='{SIGNUP_URL}'>Load these results into your free workspace</a> "
        "<a class='btn' href='mailto:support@orgdatasolutions.com?subject=Audit%20Analyzer'>"
        "Talk to us - support@orgdatasolutions.com</a></div>",
        "</main>",
        "<footer>Free tool from <a href='https://orgdatasolutions.com'>Org Data Solutions</a> "
        "&middot; John Stover &middot; <a href='mailto:support@orgdatasolutions.com'>support@orgdatasolutions.com</a> "
        "&middot; provided as-is, no warranty. Generated locally - nothing leaves your machine.</footer>",
        "</body></html>"))
    return "".join(parts)


# ----------------------------------------------------------------------------
# Mode 1: explore - is auditing on, and where?
# ----------------------------------------------------------------------------
def mode_explore(org, token, include_columns: bool):
    import os
    print("Checking environment audit settings...", flush=True)
    orgrow = api_get(org, token,
                     "organizations?$select=isauditenabled,auditretentionperiodv2,"
                     "isuseraccessauditenabled")["value"][0]
    audit_on = bool(orgrow.get("isauditenabled"))
    retention = orgrow.get("auditretentionperiodv2")
    user_access = bool(orgrow.get("isuseraccessauditenabled"))

    earliest = ""
    total_hint = ""
    if audit_on:
        first = api_get(org, token,
                        "audits?$select=createdon&$orderby=createdon asc&$top=1",
                        "odata.maxpagesize=1").get("value", [])
        earliest = first[0].get("createdon", "") if first else ""
        try:
            counts = api_get(org, token,
                             'RetrieveTotalRecordCount(EntityNames=@p)?@p=["audit"]')
            total_hint = str(counts.get("EntityRecordCountCollection", {})
                             .get("Values", [""])[0])
        except Exception:
            pass  # count is a nice-to-have; some roles can't call it

    retention_text = ("Forever" if retention == -1 else
                      f"{retention} days" if retention is not None else "Unknown")
    env_path = os.path.join(OUTPUT_DIR, "audit_environment.csv")
    f, w = open_csv(env_path, ["Setting", "Value"])
    with f:
        w.writerow(["Environment auditing", "Enabled" if audit_on else "DISABLED"])
        w.writerow(["Retention", retention_text])
        w.writerow(["User-access (login) auditing", "Enabled" if user_access else "Disabled"])
        w.writerow(["Earliest audit event", earliest or "n/a"])
        w.writerow(["Total audit events (approx.)", total_hint or "n/a"])
        w.writerow(["Checked (UTC)", datetime.datetime.now(datetime.timezone.utc)
                    .strftime("%Y-%m-%d %H:%M:%S")])

    print("Reading table-level audit flags...", flush=True)
    ents = api_get(org, token,
                   "EntityDefinitions?$select=LogicalName,DisplayName,IsAuditEnabled",
                   f"odata.maxpagesize={PAGE}")["value"]
    ents.sort(key=lambda m: (not bool((m.get("IsAuditEnabled") or {}).get("Value")),
                             m.get("LogicalName") or ""))

    cov_path = os.path.join(OUTPUT_DIR, "audit_coverage.csv")
    f, w = open_csv(cov_path, ["Table (logical name)", "Display name",
                               "Auditing", "Locked by managed solution"])
    audited = []
    audited_rows = []   # [logical, display, locked] for the HTML report
    with f:
        for m in ents:
            iae = m.get("IsAuditEnabled") or {}
            on = bool(iae.get("Value"))
            locked = not iae.get("CanBeChanged", True)
            if on:
                audited.append(m.get("LogicalName"))
                audited_rows.append([m.get("LogicalName"), label(m.get("DisplayName")), locked])
            w.writerow([m.get("LogicalName"), label(m.get("DisplayName")),
                        "On" if on else "Off", "Yes" if locked else ""])

    col_note = ""
    if include_columns:
        print(f"Reading column-level flags for {len(audited)} audited tables "
              "(one API call each)...", flush=True)
        colf, colw = open_csv(os.path.join(OUTPUT_DIR, "audit_coverage_columns.csv"),
                              ["Table", "Column (logical name)", "Display name",
                               "Audited", "Locked by managed solution"])
        with colf:
            for i, ent in enumerate(audited, 1):
                try:
                    attrs = api_get(org, token,
                                    f"EntityDefinitions(LogicalName='{ent}')/Attributes"
                                    "?$select=LogicalName,DisplayName,IsAuditEnabled")["value"]
                except urllib.error.HTTPError as e:
                    print(f"  {ent}: skipped (HTTP {e.code})", flush=True)
                    continue
                for a in attrs:
                    aiae = a.get("IsAuditEnabled") or {}
                    colw.writerow([ent, a.get("LogicalName"), label(a.get("DisplayName")),
                                   "Yes" if aiae.get("Value") else "No",
                                   "Yes" if not aiae.get("CanBeChanged", True) else ""])
                if i % 25 == 0:
                    print(f"  ...{i}/{len(audited)}", flush=True)
        col_note = " + audit_coverage_columns.csv"

    report_path = update_report(org, "explore", {
        "audit_on": audit_on,
        "retention": retention_text,
        "user_access": user_access,
        "earliest": earliest[:10] if earliest else "",
        "total_hint": total_hint,
        "tables_total": len(ents),
        "tables_audited": len(audited_rows),
        "locked_count": sum(1 for t in audited_rows if t[2]),
        "audited_tables": audited_rows,
        "columns_included": include_columns,
    })

    print()
    print("=" * 68)
    print(f"Environment auditing : {'ENABLED' if audit_on else 'DISABLED  <-- nothing is being recorded!'}")
    print(f"Retention            : {retention_text}")
    print(f"Audited tables       : {len(audited)} of {len(ents)}")
    if earliest:
        print(f"History reaches back : {earliest[:10]}")
    print(f"Output               : {env_path}, {cov_path}{col_note}")
    print(f"HTML report          : {report_path}")
    print("=" * 68)
    if not audit_on:
        print("Turn auditing on in Power Platform admin center (Environment ->")
        print("Settings -> Audit settings); only changes made AFTER that are kept.")
    print("Next step: python ods_audit_export.py export")
    print()
    print("Want this continuously warehoused with reports, alerts and a weekly")
    print("digest instead of snapshots? support@orgdatasolutions.com")
    print(f"Load these results into your free workspace: {SIGNUP_URL}")


# ----------------------------------------------------------------------------
# Mode 2: export - audit events to one CSV per table
# ----------------------------------------------------------------------------
EXPORT_HEADER = ["Changed (UTC)", "User", "Calling user", "Table", "Record",
                 "Record id", "Action", "Action detail", "Field",
                 "Previous value", "New value", "Audit id", "Transaction id"]

AUDIT_SELECT = ("auditid,createdon,operation,action,objecttypecode,transactionid,"
                "changedata,_objectid_value,_userid_value,_callinguserid_value")


def parse_changedata(raw):
    """The audit row's changedata JSON -> [(field, old, new)] (may be empty)."""
    if not raw:
        return []
    try:
        d = json.loads(raw)
        return [(a.get("logicalName"), a.get("oldValue"), a.get("newValue"))
                for a in d.get("changedAttributes", []) if a.get("logicalName")]
    except (ValueError, AttributeError):
        return []


def fetch_detail(org, token, audit_id):
    """RetrieveAuditDetails fallback -> [(field, old, new)] with display labels."""
    d = api_get(org, token,
                f"audits({audit_id})/Microsoft.Dynamics.CRM.RetrieveAuditDetails()",
                f'odata.include-annotations="{FV}"')
    detail = d.get("AuditDetail") or {}
    def flat(ent):
        vals = {}
        for k, v in (ent or {}).items():
            if k.startswith("@") or "@" in k:
                continue
            vals[k] = v
        # prefer display labels where Dataverse provides them
        for k, v in (ent or {}).items():
            if f"@{FV}" in k:
                vals[k.split("@", 1)[0]] = v
        return vals
    old, new = flat(detail.get("OldValue")), flat(detail.get("NewValue"))
    return [(k, old.get(k), new.get(k)) for k in sorted(set(old) | set(new))]


def cell(v):
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        return json.dumps(v, separators=(",", ":"))
    return str(v)


def safe_name(entity):
    return re.sub(r"[^A-Za-z0-9_]+", "_", entity or "unknown")


def mode_export(org, token, since: str, tables, want_details: bool, detail_cap: int):
    import os
    url = (f"audits?$select={AUDIT_SELECT}"
           f"&$filter=createdon ge {since}&$orderby=createdon asc")
    print(f"Exporting audit events since {since}"
          + (f" for tables: {', '.join(tables)}" if tables else "") + " ...", flush=True)

    writers = {}   # entity -> (file, csv_writer)
    counts = {}
    stats = {}     # entity -> [display, events, rows, deletes]  (HTML report)
    users = {}     # user name -> [events, deletes]
    ops = {}       # operation display name -> events
    detail_used = 0
    events = 0
    try:
        for r in api_pages(org, token, url):
            entity = r.get("objecttypecode") or "unknown"
            if tables and entity not in tables:
                continue
            events += 1
            if entity not in writers:
                path = os.path.join(OUTPUT_DIR, f"audit_{safe_name(entity)}.csv")
                writers[entity] = open_csv(path, EXPORT_HEADER)
                counts[entity] = 0
            w = writers[entity][1]

            changes = parse_changedata(r.get("changedata"))
            op = r.get("operation")

            st = stats.setdefault(entity, [fv(r, "objecttypecode") or entity, 0, 0, 0])
            st[1] += 1
            if op == 3:
                st[3] += 1
            uname = fv(r, "_userid_value") or "(unknown)"
            u = users.setdefault(uname, [0, 0])
            u[0] += 1
            u[1] += 1 if op == 3 else 0
            opname = fv(r, "operation") or "Other"
            ops[opname] = ops.get(opname, 0) + 1
            if not changes and want_details and op in (1, 2) and detail_used < detail_cap:
                try:
                    changes = fetch_detail(org, token, r.get("auditid"))
                    detail_used += 1
                except urllib.error.HTTPError:
                    changes = []

            base = [
                (r.get("createdon") or "").replace("T", " ").rstrip("Z"),
                fv(r, "_userid_value") or "",
                fv(r, "_callinguserid_value") or "",
                fv(r, "objecttypecode") or entity,
                fv(r, "_objectid_value") or "",
                r.get("_objectid_value") or "",
                fv(r, "operation") or "",
                fv(r, "action") or "",
            ]
            tail = [r.get("auditid") or "", r.get("transactionid") or ""]
            st[2] += len(changes) or 1
            if changes:
                for field, old, new in changes:
                    w.writerow(base + [field, cell(old), cell(new)] + tail)
                    counts[entity] += 1
            else:
                # deletes, access events, relationship changes, or field detail
                # not present on the audit row (see --details)
                w.writerow(base + ["", "", ""] + tail)
                counts[entity] += 1
            if events % 10000 == 0:
                print(f"  ...{events} events", flush=True)
    finally:
        for f, _ in writers.values():
            f.close()

    report_path = update_report(org, "export", {
        "since": since[:10],
        "events": events,
        "rows": sum(counts.values()),
        "files": len(writers),
        "want_details": want_details,
        "detail_used": detail_used,
        "detail_cap": detail_cap,
        "ops": ops,
        "user_count": len(users),
        "tables": sorted(([e] + s for e, s in stats.items()), key=lambda t: -t[2])[:100],
        "users": sorted(([n] + c for n, c in users.items()), key=lambda u: -u[1])[:25],
    })

    print()
    print("=" * 68)
    if not writers:
        print("No audit events found in that window.")
        print("Run 'python ods_audit_export.py explore' to confirm auditing is on.")
    for entity in sorted(counts):
        print(f"  audit_{safe_name(entity)}.csv  ({counts[entity]} rows)")
    print(f"{events} events -> {len(writers)} file(s) in .\\{OUTPUT_DIR}\\")
    print(f"HTML report: {report_path}")
    if want_details:
        print(f"RetrieveAuditDetails calls used: {detail_used}/{detail_cap}"
              + ("  (raise --detail-cap to fetch more)" if detail_used >= detail_cap else ""))
    elif events:
        print("Tip: some events keep their old/new values behind a per-event API")
        print("call - re-run with --details to fetch them (slower).")
    print("=" * 68)
    print()
    print("Running this by hand every month? We'll mirror your audit history")
    print("into a managed warehouse continuously - searchable reports, high-")
    print("risk alerts, weekly executive digest. support@orgdatasolutions.com")
    print(f"Load these results into your free workspace: {SIGNUP_URL}")


# ----------------------------------------------------------------------------
def main() -> int:
    args = sys.argv[1:]
    mode = args[0].lower() if args and not args[0].startswith("-") else ""
    def opt(name, default=None):
        return next((a.split("=", 1)[1] for a in args if a.startswith(f"--{name}=")), default)

    if mode not in ("explore", "export"):
        print(__doc__.split("Setup (one-time")[0])
        print("Usage: python ods_audit_export.py explore [--columns]")
        print("       python ods_audit_export.py export  [--days=30 | --since=YYYY-MM-DD]")
        print("                                          [--tables=contact,account]")
        print("                                          [--details] [--detail-cap=500]")
        return 1

    org, tenant, client_id, secret = load_config(CONFIG_XML)
    print(f"Connecting to {org} ...", flush=True)
    token = get_token(org, tenant, client_id, secret)

    if mode == "explore":
        mode_explore(org, token, include_columns="--columns" in args)
        return 0

    since = opt("since")
    if since:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", since):
            sys.exit("--since must be YYYY-MM-DD")
        since += "T00:00:00Z"
    else:
        days = int(opt("days", "30"))
        since = (datetime.datetime.now(datetime.timezone.utc)
                 - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    tables = [t.strip() for t in (opt("tables") or "").split(",") if t.strip()] or None
    mode_export(org, token, since, tables,
                want_details="--details" in args,
                detail_cap=int(opt("detail-cap", "500")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
