# ODS Dataverse Audit Export

**A free tool from Org Data Solutions.** Point it at a Dataverse / Dynamics
365 / Power Platform environment you administer and find out whether
auditing is really on, for which tables and columns, and then get your audit
history out as plain CSV files.

Built for the two questions every Dataverse admin eventually asks:
*"Is auditing actually turned on?"* and *"How do I get the history out?"*
Microsoft offers no bulk export from the audit views; the data is only
reachable through the Web API. This tool does that for you.

---

## What it tells you

| | |
|---|---|
| **Is auditing on?** | Environment-level auditing, retention period, user-access (sign-in) auditing, and the date of the earliest event still kept. |
| **Where?** | Every table, audited or not, and whether a managed solution locks the setting. With `--columns`, every column of every audited table. |
| **What changed** | One CSV per table, one row per changed field: old value, new value, who made the change, the calling (impersonating) user, and the transaction id that groups a multi-field save. |
| **At a glance** | A one-page HTML report: highlights, coverage, most-changed tables, most active users, deletes. |

CSV, not JSON, on purpose: it streams row by row (no memory blow-ups on
large histories), splits naturally per table, and your membership team can
open it straight in Excel.

## Safety

- **Read-only.** The tool only issues `GET` requests to the Dataverse Web API
  (plus one sign-in call to Microsoft). It never creates, updates or deletes
  a record, and never changes an audit setting.
- **Nothing leaves your machine.** No telemetry, no upload. Your data travels
  from Microsoft's servers to the output folder on your computer and nowhere
  else.
- The output **contains your audit data**, including old and new field
  values and user names. Store and share the `audit-export` folder as you
  would the CRM data itself.

## Requirements

- Python 3.9 or later. **Standard library only**: nothing to `pip install`.
- An app registration in Microsoft Entra ID with a client secret, added to
  the environment as an **Application User** with a security role that can
  read audit data (System Administrator covers it).

## Setup (~10 minutes)

1. In Microsoft Entra ID, create an app registration and give it a client
   secret.
2. In the Power Platform admin center, add it as an Application User on your
   environment with a role that can read audit data.
3. Copy the sample config and fill in your environment URL, tenant id,
   client id and client secret:

```bash
copy config.sample.xml config.xml     # macOS / Linux: cp; then fill it in
```

`config.xml` holds a secret — keep it out of source control. The tool reads
`config.xml` from the folder you run it in.

## Run it

```bash
python ods_audit_export.py explore                       # is auditing on, and where?
python ods_audit_export.py explore --columns             # plus column-level flags (slower)
python ods_audit_export.py export                        # last 30 days, one CSV per table
python ods_audit_export.py export --days=90              # a longer window
python ods_audit_export.py export --since=2026-01-01     # from a date (overrides --days)
python ods_audit_export.py export --tables=contact,account
python ods_audit_export.py export --details              # fetch old/new values missing from the audit row
python ods_audit_export.py export --details --detail-cap=2000
```

`--details` makes one extra API call per event that needs it, capped by
`--detail-cap` (default 500). Run `explore` and then `export`: the HTML
report accumulates both.

## Outputs

All in the `audit-export` folder (created if missing):

| File | What's in it |
|---|---|
| `audit_report.html` | Branded one-page summary — **start here** |
| `audit_environment.csv` | Environment settings: on/off, retention, user-access auditing, earliest event |
| `audit_coverage.csv` | One row per table: auditing on/off, locked by a managed solution |
| `audit_coverage_columns.csv` | With `--columns`: one row per column of every audited table |
| `audit_<table>.csv` | From `export`: one row per changed field |
| `_report_data.json` | The summary numbers the HTML report is drawn from |

## If auditing is off

`explore` will tell you. Turn it on in the Power Platform admin center
(**Environment → Settings → Audit settings**), then per table under
**Tables → *table* → Properties → Audit changes to its data**. Auditing only
records changes made **after** it is turned on, and Dataverse deletes history
at the end of the retention period, so export what you need before then.

## Then what?

This exports snapshots. If you would rather have your audit history mirrored
continuously into a managed warehouse — kept beyond Dataverse retention,
with searchable activity reports, before/after drill-through, staff
stewardship summaries, high-risk change alerts (deletes, merges, security
roles) and a weekly digest for your executives — that is what our hosted
**CRM Activity Review** does, and we run it for you.

The governance tools of the **ODS Data Management Platform** are free for
approved nonprofits and .org organizations. Connecting Dataverse directly is
a premium connector you can add to a free workspace.

Ask for a walkthrough on your own environment: **support@orgdatasolutions.com**

**[Load these results into your free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-audit-export)**
