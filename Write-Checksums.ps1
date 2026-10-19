<#
.SYNOPSIS
    Writes or verifies SHA256SUMS.txt for every file in the ODS Offline Toolkit.

.DESCRIPTION
    Write mode (default): hashes every file under the toolkit folder (the
    folder this script is in) and writes SHA256SUMS.txt next to this script.
    One line per file: lowercase SHA-256, two spaces, the relative path with
    forward slashes, sorted -- the format `sha256sum -c` reads.

    Skipped: SHA256SUMS.txt itself, the .git folder, and files that should
    never be in a release (real configs with secrets, Python caches, logs,
    tool output). Any skipped secret-bearing file is reported as a warning.

    Verify mode (-Verify): re-hashes every file listed in SHA256SUMS.txt and
    reports OK, FAILED or MISSING for each, plus files on disk that the list
    does not include. Exits 1 if anything is not OK.

    Run write mode as the LAST release step, after code signing: signing a
    script changes its bytes and therefore its hash.

    Works in Windows PowerShell 5.1 and PowerShell 7. Reads files only;
    writes nothing but SHA256SUMS.txt (and nothing at all with -Verify).

.PARAMETER Verify
    Check the files against SHA256SUMS.txt instead of writing it.

.PARAMETER Root
    Folder to hash. Default: the folder this script is in.

.EXAMPLE
    .\Write-Checksums.ps1
        Write SHA256SUMS.txt for the toolkit.

.EXAMPLE
    .\Write-Checksums.ps1 -Verify
        Check a downloaded copy against its SHA256SUMS.txt.

.NOTES
    Copyright (c) 2026 Org Data Solutions. MIT License (see LICENSE).
#>
[CmdletBinding()]
param(
    [switch] $Verify,
    [string] $Root
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Resolved here, not as a param default: Windows PowerShell 5.1 leaves
# $PSScriptRoot empty in param defaults when the script runs via -File.
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root     = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')
$sumsFile = Join-Path $Root 'SHA256SUMS.txt'

# Never part of a release. Matched against the relative path (forward slashes).
$skipPatterns = @(
    '^SHA256SUMS\.txt$',
    '^\.git/',
    '(^|/)__pycache__/',
    '\.pyc$',
    '(^|/)logs/',
    '(^|/)audit-export/',
    '(^|/)governance_report\.html$',
    '(^|/)governance_[a-z]+\.csv$',
    '\.bak$'
)
# Real configs hold passwords / client secrets: skip them AND warn.
$secretPatterns = @(
    '(^|/)config\.xml$',
    '(^|/)backup-config\.psd1$',
    '(^|/)\.env$',
    '\.env$',
    '(^|/)appsettings[^/]*\.json$'
)

function Get-RelativePath([string]$FullName) {
    return $FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
}

function Test-Match([string]$Rel, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($Rel -match $p) { return $true } }
    return $false
}

function Get-OrdinalSorted([string[]]$Items) {
    # Ordinal (byte-wise) order, so the output is identical on every machine
    # regardless of culture settings.
    $arr = [string[]]@($Items)
    [Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return ,$arr
}

function Get-ReleaseFiles {
    $byRel = @{}
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $rel = Get-RelativePath $f.FullName
        if (Test-Match $rel $skipPatterns) { continue }
        if (Test-Match $rel $secretPatterns) {
            Write-Warning "Skipped '$rel': real config files must not be in a release. Remove it before publishing."
            continue
        }
        $byRel[$rel] = $f.FullName
    }
    $files = @()
    foreach ($rel in (Get-OrdinalSorted @($byRel.Keys))) {
        $files += [pscustomobject]@{ Rel = $rel; Full = $byRel[$rel] }
    }
    return ,$files
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

if (-not $Verify) {
    $files = Get-ReleaseFiles
    $lines = foreach ($f in $files) { '{0}  {1}' -f (Get-Sha256 $f.Full), $f.Rel }
    # LF line endings and no BOM, so `sha256sum -c` reads it on any platform.
    $text = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($sumsFile, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("Wrote {0} ({1} files)." -f $sumsFile, $files.Count) -ForegroundColor Green
    exit 0
}

if (-not (Test-Path -LiteralPath $sumsFile)) {
    Write-Host "SHA256SUMS.txt not found in $Root" -ForegroundColor Red
    exit 1
}

$expected = @{}
foreach ($line in [System.IO.File]::ReadAllLines($sumsFile)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^([0-9a-fA-F]{64}) [ *](.+)$') {
        Write-Host "Unreadable line in SHA256SUMS.txt: $line" -ForegroundColor Red
        exit 1
    }
    $expected[$Matches[2]] = $Matches[1].ToLowerInvariant()
}

$bad = 0
foreach ($rel in (Get-OrdinalSorted @($expected.Keys))) {
    $full = Join-Path $Root ($rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Write-Host "MISSING  $rel" -ForegroundColor Red; $bad++; continue
    }
    if ((Get-Sha256 $full) -eq $expected[$rel]) {
        Write-Host "OK       $rel"
    } else {
        Write-Host "FAILED   $rel" -ForegroundColor Red; $bad++
    }
}
$onDisk = Get-ReleaseFiles
foreach ($f in $onDisk) {
    if (-not $expected.ContainsKey($f.Rel)) {
        Write-Host "NEW      $($f.Rel)  (not in SHA256SUMS.txt)" -ForegroundColor Yellow; $bad++
    }
}

if ($bad -gt 0) {
    Write-Host ("{0} problem(s). Do not use files marked FAILED, MISSING or NEW until you know why." -f $bad) -ForegroundColor Red
    exit 1
}
Write-Host ("All {0} files match SHA256SUMS.txt." -f $expected.Count) -ForegroundColor Green
exit 0
