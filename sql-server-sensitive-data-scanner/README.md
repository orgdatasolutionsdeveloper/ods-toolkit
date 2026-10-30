# SQL Server Sensitive Data Scanner

**Version 0.4.0 (beta). By John Stover, Org Data Solutions.**

Point it at a SQL Server or Azure SQL database you own and get a report of
what sensitive data is in it, who can read it, and what to fix first. It is
read-only, it runs on your own computer, and nothing leaves your machine.

---

## What it tells you

| | |
|---|---|
| **What is in there** | Every table and column, with row counts. |
| **What is sensitive** | Columns that look like personal, credential, payment, financial or health data, by **name**, and with `--sample` by the **values they hold**. |
| **Who can read it** | The logins and roles that can `SELECT` from the tables holding it. |
| **What to fix first** | Findings ranked by severity, plus a 0 to 100 score across four areas. |

The value pass is the one that matters. Name rules find `email_address`.
Only value inspection finds the column called `uid` that is full of email
addresses, or the free-text `notes` column with Social Security numbers
inside it. Run with `--sample`.

## Safety

- **Read-only.** Catalog `SELECT`s, plus `TOP (n)` reads of the columns being
  inspected when you pass `--sample`. It never writes, alters or drops
  anything.
- **Nothing leaves your machine.** No telemetry, no upload. The report is a
  set of local files. Sampled values are used in memory to classify a column
  and are never written to the outputs; only counts and shapes are.
- A **read-only login** (`db_datareader`) is enough, and is what to use.

## What you need

- **Windows, macOS or Linux** with Python 3.9 or later. On Windows,
  `run.cmd` installs Python 3.12 for you if it is missing.
- The `pyodbc` package. The scanner installs it with `pip` if it is missing.
- A SQL Server ODBC driver. On Windows the scanner installs Microsoft ODBC
  Driver 18 for SQL Server if none is found (this may show an administrator
  prompt). Driver 17 and the older drivers also work.
- A login that can read the database, or your Windows account.

## Quick start (Windows)

1. Double-click **`run.cmd`** in this folder, or open a command prompt here
   and type `run --sample`.
2. The first time, it asks four or five questions on the console (server,
   database, Windows account or SQL login, user name, password) and writes
   `config.xml` next to the script. Keep that file private: it holds the
   password.
3. It scans and prints where the report is. Open
   `sensitive-data-report\sensitive_data_report.html`.

To change the settings later, edit `config.xml` with any text editor, or
delete it and run again to be asked again. `config.sample.xml` shows every
setting with notes.

## Quick start (macOS, Linux, or Windows without run.cmd)

```bash
python3 sql_server_sensitive_data_scanner.py --sample
```

Same first-run questions, same output.

## Running it

```
run                          names only, fastest
run --sample                 also inspect values (recommended)
run --sample --rows=200      sample more values per column
run --schemas=dbo,ops        limit the scan to some schemas
run --out=C:\reports\finance choose the output folder
run --config=other.xml       use a different settings file
run --version
```

On macOS or Linux replace `run` with `python3 sql_server_sensitive_data_scanner.py`.

A scan of a few hundred tables takes under a minute without `--sample` and
a few minutes with it, depending on the server.

## Outputs

All in the `sensitive-data-report` folder next to the script (or `--out`):

| File | What is in it |
|---|---|
| `sensitive_data_report.html` | One-page summary. **Start here.** |
| `sensitive_data_findings.csv` | One row per flagged column: severity, table, column, classification, how it was detected, evidence, row count |
| `sensitive_data_tables.csv` | Table inventory: rows, columns, primary key yes/no, flagged column count |
| `sensitive_data_access.csv` | Logins and roles that can read the data, and how (role membership or explicit grant) |

## Reading the findings

Each flagged column gets a classification and a severity:

| Severity | Meaning | Examples |
|---|---|---|
| **critical** | A credential-style column whose sampled values do not look hashed. | `password`, `api_key` holding plain text |
| **high** | Regulated or high-impact data. | Social Security or tax ids, payment card numbers, health data, credentials |
| **medium** | Sensitive personal data, or any personal data confirmed by sampled values. | date of birth, salary, an email column found by its values |
| **low** | Personal data detected by column name only. | `email`, `phone`, `address`, `first_name` |

`detected_by` says whether the column name or the sampled values triggered
the finding. A value-based finding on a column whose name gives no hint is
the kind a manual review misses.

## Scoring

Four areas, averaged to an overall score out of 100:

- **Sensitive-data discovery**: capped at 55 without `--sample`, because
  column names alone cannot prove coverage.
- **Credential and regulated-data exposure**: plain-text secrets are the
  heaviest penalty.
- **Access breadth**: how many principals can read the whole database.
- **Schema hygiene**: tables without primary keys, empty tables.

A high score means *this scan* found little. It is a starting point for a
conversation, not a certification.

## Known limits (beta)

- Detection is by pattern. Expect some false positives (a column named
  `bank` that holds a blood-bank id) and some misses (a phone number stored
  as `5551234567` in an integer column is not sampled). Read the findings
  before acting on them.
- Values are sampled from the top of each table, not at random. A column
  that is empty in the first rows and filled later can be missed.
- Column-level permissions and row-level security are not read; the access
  list reports table and database level rights.
- Only SQL Server and Azure SQL. Other databases are out of scope.

## Troubleshooting

| Message | What to do |
|---|---|
| `Could not connect: ... Login failed for user` | Wrong user name or password in `config.xml`, or the login has no access to that database. |
| `Could not connect: ... server was not found or was not accessible` | Check the server name (include the instance, for example `SQL01\SQLEXPRESS`), that SQL Server allows remote connections, and the firewall. |
| `Could not connect: ... certificate chain was issued by an authority that is not trusted` | Keep `TrustServerCertificate` set to `yes` in `config.xml` (the default), or install the server's certificate. |
| `No SQL Server ODBC driver found` | Install Microsoft ODBC Driver 18 for SQL Server by hand and run again. |
| `No non-default readers found (or the login can't read permission metadata)` in the report | The login cannot read `sys.database_permissions`. Run once with a login that has `VIEW DEFINITION` to get the access list. |
| `pyodbc was installed but cannot be loaded yet` | Open a new command prompt and run again. |

## Then what?

This is a snapshot from one run. The hosted **ODS Data Management Platform**
keeps it current: catalog and profiling of every table, sensitivity tags
with role-based masking in every grid, chart, export and share link, a
scorecard with trend, a full access audit, and a weekly digest of what
changed.

The governance tools are free for approved nonprofits and .org
organizations. Connecting your SQL Server directly, so the scan runs every
day, is a premium connector you can add to a free workspace.

Ask for a walkthrough on your own data: **support@orgdatasolutions.com** ·
<https://data.orgdatasolutions.com>

**[Load these results into your free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-governance-scan)**

## License

MIT License. Copyright (c) 2026 John Stover, Org Data Solutions. Provided
as-is, without warranty.
