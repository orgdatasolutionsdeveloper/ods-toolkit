# ODS Data Governance Scan

**A free tool from Org Data Solutions.** Point it at a SQL Server / Azure SQL
database you own and get a governance-readiness report: what sensitive data is
in there, who can read it, and what to fix first.

Built for the question boards are asking right now — *"before we point AI at our
data, do we actually know what's in it?"*

---

## What it tells you

| | |
|---|---|
| **What's in there** | Every table and column, with row counts. |
| **What's sensitive** | Columns that look like PII, credentials, payment or financial data — by **name**, and with `--sample` by the **values they actually hold**. |
| **Who can read it** | The logins and roles that can `SELECT` the tables holding it. |
| **What to fix first** | Findings ranked by severity, plus a 0–100 readiness score across four axes. |

The value pass is the one that matters. Name rules find `email_address`. Only
value inspection finds the column called `uid` that is full of email addresses,
or the free-text `notes` column with SSNs buried inside it — and in testing
against a real database that is exactly what it caught.

## Safety

- **Read-only.** Catalog `SELECT`s, plus `TOP (n)` reads of the columns being
  inspected when you pass `--sample`. It never writes, alters, or drops.
- **Nothing leaves your machine.** No telemetry, no upload. The report is a
  local HTML file. (Sampled values are used in memory to classify a column and
  are never written to the outputs — only counts and shapes are.)
- A **read-only login** (`db_datareader`) is enough, and is what we recommend.

## Requirements

- Python 3.9 or later.
- The `pyodbc` package and a SQL Server ODBC driver ("ODBC Driver 18 for
  SQL Server" ships with recent SSMS; 17 also works).
- A login that can read the database. `db_datareader` is enough.

## Setup (~2 minutes)

```bash
pip install pyodbc
copy config.sample.xml config.xml     # macOS / Linux: cp; then fill it in
```

`config.xml` holds a password — keep it out of source control.

## Run it

```bash
python ods_governance_scan.py                      # names only, fastest
python ods_governance_scan.py --sample             # inspect values (recommended)
python ods_governance_scan.py --sample --rows=200  # deeper sampling
python ods_governance_scan.py --schemas=dbo,ops    # limit scope
python ods_governance_scan.py --out=./report       # choose output folder
```

## Outputs

| File | What's in it |
|---|---|
| `governance_report.html` | Branded one-page summary — **start here** |
| `governance_findings.csv` | One row per sensitive/at-risk column |
| `governance_tables.csv` | Table inventory: rows, columns, flagged counts |
| `governance_access.csv` | Principals that can read the data |

## Scoring

Four axes, averaged to an overall score out of 100:

- **Sensitive-data discovery** — capped at 55 without `--sample`, because column
  names alone cannot prove coverage.
- **Credential & regulated-data exposure** — plaintext-looking secrets are the
  heaviest penalty.
- **Access breadth** — how many principals can read the whole database.
- **Schema hygiene** — tables without primary keys, empty tables.

A high score means *this scan* found little. It is a starting point for a
conversation, not a certification.

## Then what?

This is a snapshot from one run. Governance is a standing process — data
changes, columns get added, people join and leave. The hosted **ODS Data
Management Platform** turns this report into something that runs itself:

- **Classify once, enforce everywhere** — tag a column sensitive and it's masked
  or blocked per role in every grid, chart, export, share link, *and AI answer*.
- **AI-assisted discovery** — the same value-based inspection, continuously,
  with one-click accept into enforced policy.
- **Proof on demand** — governance scorecard with trend, full access audit, and
  an exportable evidence pack for your auditor or board.
- **Weekly digest** — what changed, what's newly unclassified, who was blocked.

The governance tools are free for approved nonprofits and .org
organizations. Connecting your SQL Server directly, so the scan runs every
day, is a premium connector you can add to a free workspace.

Ask for a walkthrough on your own data: **support@orgdatasolutions.com** ·
<https://data.orgdatasolutions.com>

**[Load these results into your free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-governance-scan)**
