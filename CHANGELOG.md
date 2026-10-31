# Changelog

Every tool in this repository is beta software. Each tool carries its own
version number; the repository has no single version.

## 2026-10-30

| Tool | Version |
|---|---|
| SQL Server Sensitive Data Scanner | 0.4.0 beta |
| Dataverse Audit History Export | 0.5.0 beta |
| Dataverse to SQL Server Sync | 0.6.0 beta |
| SQL Server Backup All Databases | 0.5.0 beta |
| Public Data Product Kit (Excel) | 0.9.0 beta |

Changes since the first upload on 2026-10-19:

- New: `public-data-product-kit/`, an Excel workbook for publishing one
  trusted dataset as a public data product. Nine sections with a readiness
  status each, a publish gate, and one worked example.
- New: the APPCon 2026 session deck *Beyond the Dashboard: The Association
  as an Intelligence Platform*, in the same folder.

- Every tool was renamed so the folder and file names say what the tool does.
- Each tool folder has a `run.cmd`. Double-click it or run it from a command
  prompt. It installs what the tool needs (Python, the SQL Server ODBC driver,
  the `pyodbc` package, PowerShell 7, the `SqlServer` module) when it is
  missing, then starts the tool.
- First run with no config file: each tool asks for its settings on the
  console and writes the config file for you.
- The Sensitive Data Scanner picks whichever SQL Server ODBC driver is
  installed instead of failing when the one named in the config is absent.
- The Sensitive Data Scanner writes its four output files to a
  `sensitive-data-report` folder next to the script.
- New guide: `docs/DATAVERSE-APP-REGISTRATION.md`, the steps to create the app
  registration and application user that the two Dataverse tools sign in with.
- Author and copyright: John Stover, Org Data Solutions.

## 2026-10-19

First upload. Four tools: governance scan, Dataverse audit export, Dataverse
to SQL sync, SQL backup.
