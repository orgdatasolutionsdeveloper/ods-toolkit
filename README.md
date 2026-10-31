# Free Tools for SQL Server, Microsoft Dataverse and Public Data

**By John Stover, Org Data Solutions.** Four free, open-source command-line
tools for nonprofits, associations and any organization that runs on
Microsoft SQL Server or Microsoft Dataverse (Dynamics 365, Power Platform),
plus an Excel workbook for publishing a public data product. Run them on
your own computer, against your own systems, and keep the results.

> **Beta.** Every tool here is beta software with a version below 1.0. They
> are in real use, but expect rough edges. Try each one against a
> non-production system first and read the output before you rely on it.
> Problems and questions: **support@orgdatasolutions.com**.

> **Nothing leaves your machine.** No tool in this repository has telemetry,
> analytics or an upload step. Each one talks only to the systems you point
> it at (your SQL Server, your Dataverse environment and Microsoft's sign-in
> service) and writes its results to files on your computer. Nothing is sent
> to Org Data Solutions. Each report ends with a plain link to our sign-up
> page; it carries only the tool's name, never your data, and only if you
> click it.

---

## The tools

| Tool | Version | What it does | Changes anything? |
|---|---|---|---|
| [**SQL Server Sensitive Data Scanner**](sql-server-sensitive-data-scanner/README.md) | 0.4.0 beta | Finds sensitive data in a SQL Server or Azure SQL database (by column name and, with `--sample`, by the values themselves), lists who can read it, and scores the database 0 to 100. HTML report plus three CSV files. | No. Read-only. |
| [**Dataverse Audit History Export**](dataverse-audit-history-export/README.md) | 0.5.0 beta | Checks whether Dataverse auditing is on for each table and column, and exports the audit history to one CSV file per table, with an HTML summary. | No. Read-only. |
| [**Dataverse to SQL Server Sync**](dataverse-to-sql-server-sync/README.md) | 0.6.0 beta | Copies Dataverse tables into your own SQL Server database and keeps them current with incremental runs; builds a data dictionary and friendly-name views. | Writes to the SQL database you choose. Read-only against Dataverse. |
| [**SQL Server Backup All Databases**](sql-server-backup-all-databases/README.md) | 0.5.0 beta | Backs up every online database on one or more SQL Server instances into folders you choose, with logs and optional retention. | Writes `.bak` files; retention deletes old ones. |
| [**Public Data Product Kit**](public-data-product-kit/README.md) | 0.9.0 beta | An Excel workbook that walks you through publishing one trusted dataset as a public data product your industry can cite: nine sections, a readiness status for each, and a publish gate. Nothing to install. The folder also holds the APPCon 2026 session deck that introduced the kit. | No. A spreadsheet you fill in. |

## Running a tool

The Public Data Product Kit is a workbook, not a program: open
`public-data-product-kit/Public-Data-Product-Kit.xlsx` in Excel or
LibreOffice Calc and start on the **Start** tab.

Every other tool folder has a **`run.cmd`**. Double-click it, or open a command
prompt in the folder and type `run`. The first time it runs it does three
things:

1. **Installs what is missing.** Python 3.12, the `pyodbc` package and the
   Microsoft ODBC Driver 18 for SQL Server (scanner); PowerShell 7 (sync);
   the `SqlServer` PowerShell module (backup). Installs use `winget`, which
   is part of Windows 10 and 11, and `pip`. A driver or runtime install may
   show an administrator prompt.
2. **Asks for your settings** on the console (server names, the database,
   credentials, the app registration) and writes the tool's config file next
   to the script. The config file holds passwords or a client secret: keep it
   private. It is already excluded from source control by `.gitignore`.
3. **Runs the tool.**

After that it reads the config file and just runs. Anything you type after
`run` is passed to the tool:

```
run --sample
run export --days=90
run -Mode Refresh
```

You can also start the scripts directly (`python ...py`, `pwsh ...ps1`); see
each tool's README.

macOS and Linux: the two Python tools run with `python3`. The sync tool runs
under PowerShell 7 (`pwsh`). The backup tool is written for Windows.

## What each tool needs

| Tool | Runtime | Also needs | Credentials |
|---|---|---|---|
| SQL Server Sensitive Data Scanner | Python 3.9 or later | `pyodbc` and a SQL Server ODBC driver (installed for you on Windows) | A SQL login that can read the database (`db_datareader` is enough), or your Windows account |
| Dataverse Audit History Export | Python 3.9 or later | Nothing: standard library only | An Entra ID app registration that is an application user in the environment, see [docs/DATAVERSE-APP-REGISTRATION.md](docs/DATAVERSE-APP-REGISTRATION.md) |
| Dataverse to SQL Server Sync | PowerShell 7.2 or later | Nothing | The same app registration, plus a SQL login that can create tables and views in the target database |
| SQL Server Backup All Databases | Windows PowerShell 5.1 or PowerShell 7 | The `SqlServer` module (installed for you) | A login with `BACKUP DATABASE` permission, or your Windows account |
| Public Data Product Kit | Excel 2016 or later, or LibreOffice Calc | Nothing: no macros, no add-ins | None |

## Checking the download

Every file is listed in `SHA256SUMS.txt` with its SHA-256 hash. In
PowerShell, from the repository folder:

```powershell
.\Write-Checksums.ps1 -Verify
```

or, on macOS, Linux or Git Bash:

```bash
sha256sum -c SHA256SUMS.txt
```

Any `FAILED` line means that file differs from the release. Do not run it.

## Running the PowerShell scripts directly

`run.cmd` starts PowerShell with `-ExecutionPolicy Bypass`, so the scripts
run without any change to your settings. If you start a `.ps1` file
yourself, Windows may refuse because files downloaded from the internet are
marked as such and the scripts are **not yet signed** (see
[docs/CODE-SIGNING.md](docs/CODE-SIGNING.md)). After verifying the
checksums, clear the mark:

```powershell
Get-ChildItem -Recurse -File | Unblock-File
```

## Folder layout

```
ods-toolkit/
  README.md                            this file
  CHANGELOG.md                         versions and what changed
  LICENSE                              MIT License
  SHA256SUMS.txt                       SHA-256 of every file
  Write-Checksums.ps1                  writes / verifies SHA256SUMS.txt
  docs/DATAVERSE-APP-REGISTRATION.md   how to create the app registration the Dataverse tools use
  docs/CODE-SIGNING.md                 how releases will be signed
  sql-server-sensitive-data-scanner/   Python: sensitive-data scan of a SQL Server database
  dataverse-audit-history-export/      Python: Dataverse audit settings check and history export
  dataverse-to-sql-server-sync/        PowerShell: Dataverse tables copied into SQL Server
  sql-server-backup-all-databases/     PowerShell: back up every database on an instance
  public-data-product-kit/             Excel: the nine-section Public Data Product Kit workbook,
                                       plus the APPCon 2026 session deck (PowerPoint)
```

## Free workspace

The governance tools of the hosted **ODS Data Management Platform** are free
for approved nonprofits and .org organizations: data catalog and profiling,
sensitivity tags with role-based masking, access audit, evidence pack and a
weekly digest. Each tool's report links to the sign-up page. The same
workspace runs the Public Data Product Kit online, with a public page for
each finished product.

## License, customized versions and support

These tools are open source under the [MIT License](LICENSE): use them,
change them and share them, including in commercial work, as long as the
copyright notice stays with the code.

They grew out of work John Stover built for specific clients at Org Data
Solutions. Organizations that run a customized version are welcome to keep
it, and to maintain their own fork if they prefer; the MIT License allows
that without asking.

The tools are provided as-is, without warranty. Questions and bug reports:
**support@orgdatasolutions.com**.
