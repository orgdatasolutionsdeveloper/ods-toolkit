# Dataverse Audit History Export

**Version 0.5.0 (beta). By John Stover, Org Data Solutions.**

Point it at a Dataverse, Dynamics 365 or Power Platform environment you
administer and find out whether auditing is really on, for which tables and
columns, and then get the audit history out as plain CSV files. It is
read-only, it runs on your own computer, and nothing leaves your machine.

Microsoft offers no bulk export from the audit views; the data is only
reachable through the Web API. This tool does that for you.

---

## What it tells you

| | |
|---|---|
| **Is auditing on?** | Environment-level auditing, the retention period, user-access (sign-in) auditing, and the date of the earliest event still kept. |
| **Where?** | Every table, audited or not, and whether a managed solution locks the setting. With `--columns`, every column of every audited table. |
| **What changed** | One CSV per table, one row per changed field: old value, new value, who made the change, the calling (impersonating) user, and the transaction id that groups a multi-field save. |
| **At a glance** | A one-page HTML report: highlights, coverage, most-changed tables, most active users, deletes. |

CSV rather than JSON on purpose: it streams row by row (no memory problems
on large histories), splits naturally per table, and opens in Excel.

## Safety

- **Read-only.** The tool only sends `GET` requests to the Dataverse Web API,
  plus one sign-in call to Microsoft. It never creates, updates or deletes a
  record, and never changes an audit setting.
- **Nothing leaves your machine.** No telemetry, no upload. Your data travels
  from Microsoft's servers to the output folder on your computer and nowhere
  else.
- The output **contains your audit data**, including old and new field
  values and user names. Store and share the `audit-export` folder as you
  would the CRM data itself.

## What you need

- **Windows, macOS or Linux** with Python 3.9 or later. On Windows,
  `run.cmd` installs Python 3.12 for you if it is missing. Nothing else to
  install: the tool uses only Python's standard library.
- **An app registration** that is an application user in the environment,
  with a security role that can read audit data. Creating one takes about
  ten minutes: follow
  [docs/DATAVERSE-APP-REGISTRATION.md](../docs/DATAVERSE-APP-REGISTRATION.md).
  You end up with four values: environment URL, tenant id, client id and
  client secret.

## Quick start (Windows)

1. Double-click **`run.cmd`** in this folder, or open a command prompt here
   and type `run`.
2. It asks what you want to do: check the audit settings, export the
   history, or both.
3. The first time, it asks for the four app registration values and writes
   `config.xml` next to the script. Keep that file private: it holds the
   client secret.
4. It runs and prints where the files are. Open
   `audit-export\audit_report.html`.

To change the settings later, edit `config.xml` with any text editor, or
delete it and run again to be asked again. `config.sample.xml` shows the
format.

## Quick start (macOS, Linux, or Windows without run.cmd)

```bash
python3 dataverse_audit_history_export.py
```

Same questions, same output.

## Running it

```
run explore                        is auditing on, and where?
run explore --columns              plus column-level flags (slower: one call per table)
run export                         last 30 days, one CSV per table
run export --days=90               a longer window
run export --since=2026-01-01      from a date (overrides --days)
run export --tables=contact,account
run export --details               fetch old/new values that are not on the audit row
run export --details --detail-cap=2000
run --version
```

On macOS or Linux replace `run` with `python3 dataverse_audit_history_export.py`.

`--details` makes one extra API call per event that needs it, capped by
`--detail-cap` (default 500). Run `explore` and then `export`: the HTML
report shows both.

How long it takes: `explore` finishes in seconds. `export` reads 5,000
events per API call; a month of a busy environment (a few hundred thousand
events) takes a few minutes. Dataverse may slow the tool down under its
service protection limits; the tool waits and retries by itself.

## Outputs

All in the `audit-export` folder next to the script (created if missing):

| File | What is in it |
|---|---|
| `audit_report.html` | One-page summary. **Start here.** |
| `audit_environment.csv` | Environment settings: on/off, retention, user-access auditing, earliest event |
| `audit_coverage.csv` | One row per table: auditing on/off, locked by a managed solution |
| `audit_coverage_columns.csv` | With `--columns`: one row per column of every audited table |
| `audit_<table>.csv` | From `export`: one row per changed field |
| `_report_data.json` | The summary numbers the HTML report is drawn from |

Columns of the per-table CSV files:

| Column | Meaning |
|---|---|
| Changed (UTC) | When the change was recorded |
| User | Who made the change |
| Calling user | The impersonating user, when an integration acted on someone's behalf |
| Table, Record, Record id | The table and the record's display name and id |
| Action, Action detail | Create, Update, Delete, Access, and so on |
| Field, Previous value, New value | One row per field that changed. Empty for deletes, access events and relationship changes. |
| Audit id, Transaction id | The audit row's id, and the id that groups all fields saved in one operation |

## If auditing is off

`explore` tells you. Turn it on in the Power Platform admin center
(**Environment > Settings > Audit settings**), then per table under
**Tables > (table) > Properties > Audit changes to its data**. Auditing only
records changes made **after** it is turned on, and Dataverse deletes history
at the end of the retention period, so export what you need before then.

## Known limits (beta)

- Some events keep their old and new values behind a per-event API call.
  Without `--details` those rows show the action but empty field values.
  With it, the tool fetches them up to `--detail-cap` events per run.
- History older than the environment's retention period is gone before the
  tool can read it. Export on a schedule if you need to keep it.
- Option set and lookup values are exported as Dataverse returns them in the
  audit row: usually the display label, sometimes the raw id.
- Very large exports (millions of events) work, but take hours and produce
  files Excel cannot open in full. Narrow the window with `--since` and
  `--tables`.

## Troubleshooting

| Message | What to do |
|---|---|
| `Sign-in failed (HTTP 400/401)` with `AADSTS7000215` | The client secret is wrong or expired. Create a new one and put it in `config.xml`. |
| `Sign-in failed` with `AADSTS700016` | `ClientId` or `TenantId` is wrong. |
| `HTTP Error 401` after sign-in | The app registration is not an application user in this environment, or `OrgUrl` points at a different environment. |
| `HTTP Error 403` | The application user's security role cannot read audit data or that table. |
| `(throttled, waiting 15s...)` | Normal under load. The tool waits and continues. |
| `Config file ... is missing <ClientSecret>` | Fill in all four values in `config.xml`, or delete the file and run again. |

See [docs/DATAVERSE-APP-REGISTRATION.md](../docs/DATAVERSE-APP-REGISTRATION.md)
for the setup steps behind the first four rows.

## Then what?

This exports snapshots. If you would rather have your audit history
mirrored continuously into a managed warehouse, kept beyond Dataverse
retention, with searchable activity reports, before/after drill-through,
staff stewardship summaries, high-risk change alerts (deletes, merges,
security roles) and a weekly digest for your executives, that is what the
hosted **CRM Activity Review** does.

The governance tools of the **ODS Data Management Platform** are free for
approved nonprofits and .org organizations. Connecting Dataverse directly is
a premium connector you can add to a free workspace.

Ask for a walkthrough on your own environment: **support@orgdatasolutions.com**

**[Load these results into your free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-audit-export)**

## License

MIT License. Copyright (c) 2026 John Stover, Org Data Solutions. Provided
as-is, without warranty.
