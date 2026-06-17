<#
.SYNOPSIS
    ADO Backlog Migration - Setup and Run Script
    Uses: nkdAgility Azure DevOps Migration Tools (v16+)
    Docs: https://devopsmigration.io/

.DESCRIPTION
    Step 1: Install the migration tool
    Step 2: Add the ReflectedWorkItemId custom field to both projects
    Step 3: Edit configuration.json with your org/project/PAT details
    Step 4: Run this script in DRY-RUN mode first, then for real

.NOTES
    PREREQUISITES:
    - winget (Windows Package Manager) available
    - PAT tokens for both source and target ADO organisations
      Required scopes: Work Items (Read & Write), Project and Team (Read)
    - "ReflectedWorkItemId" custom field added to both process templates (see below)
#>

param(
    [switch]$DryRun,
    [switch]$SkipInstall,
    [string]$ConfigFile = ".\configuration.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 0. Prerequisites check ────────────────────────────────────────────────────
Write-Host "`n=== ADO Migration Tool ===" -ForegroundColor Cyan

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget not found. Install Windows Package Manager from https://aka.ms/getwinget"
    exit 1
}

# ── 1. Install the migration tool ─────────────────────────────────────────────
if (-not $SkipInstall) {
    Write-Host "`nInstalling nkdAgility Azure DevOps Migration Tools via winget..." -ForegroundColor Yellow
    Write-Host "NOTE: Do not run this as an elevated (admin) prompt." -ForegroundColor Gray
    winget install nkdAgility.AzureDevOpsMigrationTools --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Error "winget install failed (exit code $LASTEXITCODE)."
        exit 1
    }
    Write-Host "Tool installed." -ForegroundColor Green
}

# Verify tool is available
if (-not (Get-Command devopsmigration -ErrorAction SilentlyContinue)) {
    Write-Error "'devopsmigration' command not found. Open a new terminal so the PATH update takes effect, then re-run."
    exit 1
}

# ── 2. Validate config file ───────────────────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$sourceOrg  = $config.MigrationTools.Endpoints.Source.Collection
$sourceProj = $config.MigrationTools.Endpoints.Source.Project
$targetOrg  = $config.MigrationTools.Endpoints.Target.Collection
$targetProj = $config.MigrationTools.Endpoints.Target.Project
$sourcePat  = $config.MigrationTools.Endpoints.Source.Authentication.AccessToken
$targetPat  = $config.MigrationTools.Endpoints.Target.Authentication.AccessToken

if ([string]::IsNullOrWhiteSpace($sourceOrg) -or [string]::IsNullOrWhiteSpace($sourcePat)) {
    Write-Error "configuration.json is missing Collection or AccessToken for Source. Update the config first."
    exit 1
}

Write-Host "`nSource : $sourceOrg / $sourceProj" -ForegroundColor Cyan
Write-Host "Target : $targetOrg / $targetProj" -ForegroundColor Cyan

# ── 3. Validate PAT connectivity (lightweight API call) ───────────────────────
function Test-AdoConnection {
    param($OrgUrl, $Project, $Pat, $Label)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    $url = "$OrgUrl$Project/_apis/wit/workitemtypes?api-version=7.1"
    try {
        $raw = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Basic $b64" } -Method Get -TimeoutSec 15
        $response = if ($raw -is [string]) { $raw | ConvertFrom-Json -AsHashtable } else { $raw }
        Write-Host "$Label connection OK ($($response.count) work item types found)" -ForegroundColor Green
    }
    catch {
        Write-Error "$Label connection FAILED. Check org URL, project name, and PAT. Error: $_"
        exit 1
    }
}

Write-Host "`nValidating connections..." -ForegroundColor Yellow
Test-AdoConnection $sourceOrg $sourceProj $sourcePat "Source"
Test-AdoConnection $targetOrg $targetProj $targetPat "Target"

# ── 4. Check for ReflectedWorkItemId custom field ─────────────────────────────
Write-Host "`nNOTE: The migration tool requires a custom field 'Custom.ReflectedWorkItemId'" -ForegroundColor Yellow
Write-Host "      If not already added, follow these steps:" -ForegroundColor Yellow
Write-Host "      1. Go to: https://dev.azure.com/<org>/_settings/process" -ForegroundColor Gray
Write-Host "      2. Open the Agile process > Work Item Types > User Story (and each type)" -ForegroundColor Gray
Write-Host "      3. Add a new field: Name='ReflectedWorkItemId', Type=Text (single line)" -ForegroundColor Gray
Write-Host "      4. Repeat for Epic, Feature, Task, Bug, Issue" -ForegroundColor Gray
Write-Host "      (or use the script in: https://nkdagility.com/learn/azure-devops-migration-tools/)" -ForegroundColor Gray

# ── 5. Create logs directory ──────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path ".\logs" | Out-Null

# ── 6. Run migration ──────────────────────────────────────────────────────────
Write-Host "`n=== Starting Migration ===" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "DRY-RUN mode: config and connection validation complete. No migration command was executed." -ForegroundColor Yellow
    Write-Host "NOTE: devopsmigration v16.3.3 'execute' does not support a --dryRun flag." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "LIVE mode: migrating work items and area/iteration paths`n" -ForegroundColor Red
    $confirm = Read-Host "Type 'yes' to proceed"
    if ($confirm -ne "yes") {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
    devopsmigration execute --config $ConfigFile
}

Write-Host "`nMigration complete." -ForegroundColor Green
