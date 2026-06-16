<#
.SYNOPSIS
    Migrate ADO Process Customisations (custom fields, states, rules) between organisations.
    Run this BEFORE run-migration.ps1 so that custom fields exist on the target.

.DESCRIPTION
    Uses ADO REST API (Processes / Inherited Process) to:
      1. Discover the inherited process used by each project
      2. Create custom work item types that exist on source but not target
      3. Export custom fields from source and create them on the target process
      4. Add fields to the matching work item types on target
      5. Export custom states and create them on target

    LIMITATIONS:
      - Only works with INHERITED processes (Agile/Scrum/CMMI-based).
        XML/hosted-XML processes cannot be migrated this way.
      - System fields (System.*) are skipped — they always exist.
      - Field controls/layout positions are NOT migrated (cosmetic only).
      - Custom WIT backlog/board behaviour (levels, colour rules) is not migrated.

.PARAMETER SourceOrg
    Source org URL, e.g. https://dev.azure.com/my-source-org

.PARAMETER SourceProject
    Source project name

.PARAMETER SourcePat
    Source PAT with scopes: Process (Read), Project and Team (Read)

.PARAMETER TargetOrg
    Target org URL

.PARAMETER TargetProject
    Target project name

.PARAMETER TargetPat
    Target PAT with scopes: Process (Read & Write), Project and Team (Read)

.PARAMETER WhatIf
    Print what would be created without making changes

.EXAMPLE
    .\migrate-process.ps1 `
        -SourceOrg "https://dev.azure.com/old-org/" `
        -SourceProject "MyProject" `
        -SourcePat "xxxx" `
        -TargetOrg "https://dev.azure.com/new-org/" `
        -TargetProject "MyProject" `
        -TargetPat "yyyy"

    .\migrate-process.ps1 ... -WhatIf   # dry-run
#>

param(
    [Parameter(Mandatory)][string]$SourceOrg,
    [Parameter(Mandatory)][string]$SourceProject,
    [Parameter(Mandatory)][string]$SourcePat,
    [Parameter(Mandatory)][string]$TargetOrg,
    [Parameter(Mandatory)][string]$TargetProject,
    [Parameter(Mandatory)][string]$TargetPat,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Normalise trailing slash
$SourceOrg = $SourceOrg.TrimEnd('/')
$TargetOrg = $TargetOrg.TrimEnd('/')

# ── Helpers ───────────────────────────────────────────────────────────────────

function Get-AuthHeader ([string]$Pat) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    return @{ Authorization = "Basic $b64"; "Content-Type" = "application/json" }
}

function Invoke-Ado {
    param(
        [string]$Url,
        [string]$Pat,
        [string]$Method = "GET",
        [object]$Body = $null
    )
    $headers = Get-AuthHeader $Pat
    $params  = @{ Uri = $Url; Headers = $headers; Method = $Method; TimeoutSec = 30 }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $msg = $_.Exception.Response ? (New-Object IO.StreamReader $_.Exception.Response.GetResponseStream()).ReadToEnd() : $_
        Write-Warning "  API call failed: $Url`n  $msg"
        return $null
    }
}

function Get-ProjectProcess ([string]$Org, [string]$Project, [string]$Pat) {
    # Get the process type ID used by the project
    $proj = Invoke-Ado "$Org/$Project/_apis/project?api-version=7.1" $Pat
    $processTemplateTypeId = $proj.capabilities.processTemplate.templateTypeId
    if (-not $processTemplateTypeId) {
        throw "Could not determine process template for project '$Project' in '$Org'."
    }
    # Find the matching inherited process
    $processes = Invoke-Ado "$Org/_apis/work/processes?api-version=7.1" $Pat
    $process   = $processes.value | Where-Object { $_.typeId -eq $processTemplateTypeId }
    if (-not $process) {
        # Fall back: match by parent type (the project may use the base template directly)
        $process = $processes.value | Where-Object {
            $_.parentProcessTypeId -eq $processTemplateTypeId -or $_.typeId -eq $processTemplateTypeId
        } | Select-Object -First 1
    }
    if (-not $process) {
        throw "No process found for templateTypeId '$processTemplateTypeId'. Ensure the org uses inherited processes."
    }
    return $process
}

# ── 0. Banner ─────────────────────────────────────────────────────────────────
Write-Host "`n=== ADO Process Migration ===" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "  [WHAT-IF MODE — no changes will be made]" -ForegroundColor Yellow }

# ── 1. Discover processes ─────────────────────────────────────────────────────
Write-Host "`n[1/5] Discovering processes..." -ForegroundColor Yellow

$srcProcess = Get-ProjectProcess $SourceOrg $SourceProject $SourcePat
$tgtProcess = Get-ProjectProcess $TargetOrg $TargetProject $TargetPat

Write-Host "  Source process : $($srcProcess.name)  (id: $($srcProcess.typeId))" -ForegroundColor Cyan
Write-Host "  Target process : $($tgtProcess.name)  (id: $($tgtProcess.typeId))" -ForegroundColor Cyan

if ($srcProcess.isSystem -and $tgtProcess.isSystem) {
    Write-Warning "  Both processes appear to be system (non-inherited) processes. Custom field migration via API is not supported for XML/hosted-XML processes. Continuing to check for fields anyway..."
}

# ── 2. Migrate custom work item types ────────────────────────────────────────
Write-Host "`n[2/5] Migrating custom work item types..." -ForegroundColor Yellow

$srcWITs = Invoke-Ado "$SourceOrg/_apis/work/processes/$($srcProcess.typeId)/workItemTypes?api-version=7.1" $SourcePat
$tgtWITs = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/workItemTypes?api-version=7.1" $TargetPat

$tgtWitNames = $tgtWITs.value | ForEach-Object { $_.name }

# Only WITs where customizationType -eq "custom" are truly new types (not inherited modifications)
$customSrcWITs = $srcWITs.value | Where-Object { $_.customizationType -eq "custom" }
Write-Host "  Found $($customSrcWITs.Count) custom work item type(s) on source process."

foreach ($srcWit in $customSrcWITs) {
    if ($tgtWitNames -contains $srcWit.name) {
        Write-Host "  [SKIP]   '$($srcWit.name)' — already exists on target" -ForegroundColor Gray
        continue
    }

    # Colour must be a 6-char hex string without '#'
    $colour = if ($srcWit.color) { $srcWit.color.TrimStart('#') } else { 'e87025' }
    $icon   = if ($srcWit.icon)  { $srcWit.icon }                 else { 'icon_list'  }

    $body = @{
        name        = $srcWit.name
        description = $srcWit.description
        color       = $colour
        icon        = $icon
        isDisabled  = $false
    }

    if ($WhatIf) {
        Write-Host "  [WOULD CREATE] WIT: '$($srcWit.name)'  color=#$colour  icon=$icon" -ForegroundColor Yellow
    } else {
        Write-Host "  [CREATE] WIT: '$($srcWit.name)'" -ForegroundColor Green
        $result = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/workItemTypes?api-version=7.1" $TargetPat "POST" $body
        if (-not $result) {
            Write-Warning "    Failed to create WIT '$($srcWit.name)'"
        }
    }
}

# Refresh target WIT list so later steps see any newly created types
$tgtWITs = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/workItemTypes?api-version=7.1" $TargetPat

# ── 3. Migrate custom process-level fields ────────────────────────────────────
Write-Host "`n[3/5] Migrating custom fields..." -ForegroundColor Yellow

# Get all fields defined at the process level on source
$srcFields = Invoke-Ado "$SourceOrg/_apis/work/processes/$($srcProcess.typeId)/fields?api-version=7.1" $SourcePat
$tgtFields = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/fields?api-version=7.1" $TargetPat

$tgtFieldRefs = $tgtFields.value | ForEach-Object { $_.referenceName } | Where-Object { $_ }

$customFields = $srcFields.value | Where-Object {
    $_.referenceName -notlike "System.*" -and
    $_.referenceName -notlike "Microsoft.VSTS.*" -and
    $_.customization -ne "system"
}

Write-Host "  Found $($customFields.Count) custom field(s) on source process."

foreach ($field in $customFields) {
    if ($tgtFieldRefs -contains $field.referenceName) {
        Write-Host "  [SKIP]   $($field.referenceName) — already exists on target" -ForegroundColor Gray
        continue
    }

    $body = @{
        referenceName = $field.referenceName
        name          = $field.name
        type          = $field.type
        description   = $field.description
    }

    if ($WhatIf) {
        Write-Host "  [WOULD CREATE] Field: $($field.referenceName) ($($field.type))" -ForegroundColor Yellow
    } else {
        Write-Host "  [CREATE] Field: $($field.referenceName) ($($field.type))" -ForegroundColor Green
        $result = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/fields?api-version=7.1" $TargetPat "POST" $body
        if (-not $result) { Write-Warning "    Failed to create field $($field.referenceName)" }
    }
}

# ── 4. Add fields to work item types ─────────────────────────────────────────
Write-Host "`n[4/5] Adding fields to work item types..." -ForegroundColor Yellow

# $srcWITs / $tgtWITs already populated (and refreshed after WIT creation above)

foreach ($srcWit in $srcWITs.value) {
    $tgtWit = $tgtWITs.value | Where-Object { $_.name -eq $srcWit.name } | Select-Object -First 1
    if (-not $tgtWit) {
        Write-Warning "  Work item type '$($srcWit.name)' not found on target — skipping."
        continue
    }

    $srcWitFields = Invoke-Ado "$SourceOrg/_apis/work/processes/$($srcProcess.typeId)/workItemTypes/$($srcWit.referenceName)/fields?api-version=7.1" $SourcePat
    $tgtWitFields = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/workItemTypes/$($tgtWit.referenceName)/fields?api-version=7.1" $TargetPat

    $tgtWitFieldRefs = $tgtWitFields.value | ForEach-Object { $_.referenceName } | Where-Object { $_ }

    $customWitFields = $srcWitFields.value | Where-Object {
        $_.referenceName -notlike "System.*" -and
        $_.referenceName -notlike "Microsoft.VSTS.*" -and
        $_.customization -ne "system"
    }

    foreach ($f in $customWitFields) {
        if ($tgtWitFieldRefs -contains $f.referenceName) { continue }

        $body = @{
            referenceName = $f.referenceName
            required      = $f.required
            readOnly      = $f.readOnly
            defaultValue  = $f.defaultValue
            allowGroups   = $f.allowGroups
        }

        if ($WhatIf) {
            Write-Host "  [WOULD ADD]  $($f.referenceName) → $($srcWit.name)" -ForegroundColor Yellow
        } else {
            Write-Host "  [ADD]  $($f.referenceName) → $($srcWit.name)" -ForegroundColor Green
            $result = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/workItemTypes/$($tgtWit.referenceName)/fields?api-version=7.1" $TargetPat "POST" $body
            if (-not $result) { Write-Warning "    Failed to add $($f.referenceName) to $($srcWit.name)" }
        }
    }
}

# ── 5. Migrate custom states ──────────────────────────────────────────────────
Write-Host "`n[5/5] Migrating custom states..." -ForegroundColor Yellow

foreach ($srcWit in $srcWITs.value) {
    $tgtWit = $tgtWITs.value | Where-Object { $_.name -eq $srcWit.name } | Select-Object -First 1
    if (-not $tgtWit) { continue }

    $srcStates = Invoke-Ado "$SourceOrg/_apis/work/processes/$($srcProcess.typeId)/workItemTypes/$($srcWit.referenceName)/states?api-version=7.1" $SourcePat
    $tgtStates = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/workItemTypes/$($tgtWit.referenceName)/states?api-version=7.1" $TargetPat

    $tgtStateNames = $tgtStates.value | ForEach-Object { $_.name }

    $customStates = $srcStates.value | Where-Object { $_.customizationType -eq "custom" }

    foreach ($state in $customStates) {
        if ($tgtStateNames -contains $state.name) {
            Write-Host "  [SKIP]   State '$($state.name)' on '$($srcWit.name)' — already exists" -ForegroundColor Gray
            continue
        }

        $body = @{
            name           = $state.name
            color          = $state.color
            stateCategory  = $state.stateCategory
            order          = $state.order
        }

        if ($WhatIf) {
            Write-Host "  [WOULD CREATE] State '$($state.name)' on '$($srcWit.name)'" -ForegroundColor Yellow
        } else {
            Write-Host "  [CREATE] State '$($state.name)' on '$($srcWit.name)'" -ForegroundColor Green
            $result = Invoke-Ado "$TargetOrg/_apis/work/processes/$($tgtProcess.typeId)/workItemTypes/$($tgtWit.referenceName)/states?api-version=7.1" $TargetPat "POST" $body
            if (-not $result) { Write-Warning "    Failed to create state '$($state.name)' on '$($srcWit.name)'" }
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n=== Process migration complete ===" -ForegroundColor Cyan
if ($WhatIf) {
    Write-Host "Re-run without -WhatIf to apply changes." -ForegroundColor Yellow
} else {
    Write-Host "Next step: run .\run-migration.ps1 to migrate work items." -ForegroundColor Green
}
