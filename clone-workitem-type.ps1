<#
.SYNOPSIS
    Clone an Azure DevOps inherited-process work item type within the same process.

.DESCRIPTION
    Uses the Azure DevOps Inherited Process REST API to create a new custom work
    item type in the same process as an existing work item type, then copies
    fields, visible form controls, and custom workflow states where the API
    allows it.

    This script works with inherited processes only. XML/hosted-XML processes
    are not supported by these REST APIs.

    LIMITATIONS:
            - Visible field controls are copied into matching form groups. HTML field
                controls, such as Acceptance Criteria, are copied into a new group when
                Azure DevOps does not allow adding them to an existing group. Pages and
                sections must already exist on the target work item type.
            - Backlog levels and board behavior are not copied by this script.
      - Rules are not copied.
            - Core System.* fields are skipped because Azure DevOps manages them.

.PARAMETER Org
    Azure DevOps organisation URL, e.g. https://dev.azure.com/my-org

.PARAMETER Pat
    PAT with Process (Read & Write) and Project and Team (Read) scopes.

.PARAMETER Project
    Project whose inherited process should be used. Provide Project,
    ProcessName, or ProcessId.

.PARAMETER ProcessName
    Process name to use. Provide Project, ProcessName, or ProcessId.

.PARAMETER ProcessId
    Process typeId to use. Provide Project, ProcessName, or ProcessId.

.PARAMETER SourceWorkItemType
    Source work item type name or referenceName, e.g. User Story or
    Microsoft.VSTS.WorkItemTypes.UserStory.

.PARAMETER NewWorkItemTypeName
    Name for the cloned work item type.

.PARAMETER NewDescription
    Optional description for the cloned work item type.

.EXAMPLE
    .\clone-workitem-type.ps1 `
        -Org "https://dev.azure.com/my-org" `
        -Project "MyProject" `
        -Pat "xxxx" `
        -SourceWorkItemType "User Story" `
        -NewWorkItemTypeName "Partner Story" `
        -WhatIf

.EXAMPLE
    .\clone-workitem-type.ps1 `
        -Org "https://dev.azure.com/my-org" `
        -ProcessName "My Inherited Agile" `
        -Pat "xxxx" `
        -SourceWorkItemType "Custom.SourceType" `
        -NewWorkItemTypeName "Custom Clone"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$Org,
    [Parameter(Mandatory)][string]$Pat,
    [string]$Project,
    [string]$ProcessName,
    [string]$ProcessId,
    [Parameter(Mandatory)][string]$SourceWorkItemType,
    [Parameter(Mandatory)][string]$NewWorkItemTypeName,
    [string]$NewDescription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Org = $Org.TrimEnd('/')

function Get-AuthHeader {
    param([Parameter(Mandatory)][string]$Token)

    $encodedToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
    return @{
        Authorization = "Basic $encodedToken"
        "Content-Type" = "application/json"
    }
}

function Get-ErrorBody {
    param([Parameter(Mandatory)]$ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($response) {
        $content = $response.PSObject.Properties["Content"]
        if ($content -and $content.Value) {
            try {
                return $content.Value.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            catch {
            }
        }

        $streamMethod = $response.PSObject.Methods["GetResponseStream"]
        if ($streamMethod) {
            $stream = $response.GetResponseStream()
            if ($stream) {
                return (New-Object IO.StreamReader $stream).ReadToEnd()
            }
        }
    }

    return $ErrorRecord.ToString()
}

function Invoke-Ado {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Token,
        [string]$Method = "GET",
        [object]$Body = $null
    )

    $parameters = @{
        Uri = $Url
        Headers = Get-AuthHeader -Token $Token
        Method = $Method
        TimeoutSec = 30
    }

    if ($null -ne $Body) {
        $parameters.Body = ($Body | ConvertTo-Json -Depth 20)
    }

    try {
        return Invoke-RestMethod @parameters
    }
    catch {
        $message = Get-ErrorBody -ErrorRecord $_
        throw "Azure DevOps API call failed: $Method $Url`n$message"
    }
}

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $Default
}

function Add-OptionalProperty {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $Source.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) {
        $Target[$Name] = $property.Value
    }
}

function Get-Processes {
    return Invoke-Ado -Url "$Org/_apis/work/processes?api-version=7.1" -Token $Pat
}

function Resolve-Process {
    $selectorCount = @($Project, $ProcessName, $ProcessId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($selectorCount -ne 1) {
        throw "Provide exactly one of -Project, -ProcessName, or -ProcessId."
    }

    $processes = Get-Processes

    if ($ProcessId) {
        $match = $processes.value | Where-Object { $_.typeId -eq $ProcessId } | Select-Object -First 1
    }
    elseif ($ProcessName) {
        $match = $processes.value | Where-Object { $_.name -eq $ProcessName } | Select-Object -First 1
    }
    else {
        $encodedProject = [uri]::EscapeDataString($Project)
        $projectInfo = Invoke-Ado -Url "$Org/$encodedProject/_apis/project?api-version=7.1" -Token $Pat
        $templateTypeId = $projectInfo.capabilities.processTemplate.templateTypeId
        if (-not $templateTypeId) {
            throw "Could not determine the process template for project '$Project'."
        }

        $match = $processes.value | Where-Object { $_.typeId -eq $templateTypeId } | Select-Object -First 1
    }

    if (-not $match) {
        throw "Could not find the requested process in '$Org'."
    }

    if (Get-ObjectProperty -InputObject $match -Name "isSystem" -Default $false) {
        throw "Process '$($match.name)' is a system process. Clone the type in an inherited process instead."
    }

    return $match
}

function Get-WorkItemTypes {
    param([Parameter(Mandatory)][string]$ResolvedProcessId)

    return Invoke-Ado -Url "$Org/_apis/work/processes/$ResolvedProcessId/workItemTypes?api-version=7.1" -Token $Pat
}

function Find-WorkItemType {
    param(
        [Parameter(Mandatory)]$WorkItemTypes,
        [Parameter(Mandatory)][string]$NameOrReferenceName
    )

    return $WorkItemTypes.value |
        Where-Object { $_.name -eq $NameOrReferenceName -or $_.referenceName -eq $NameOrReferenceName } |
        Select-Object -First 1
}

function Get-WorkItemTypeFields {
    param(
        [Parameter(Mandatory)][string]$ResolvedProcessId,
        [Parameter(Mandatory)][string]$ReferenceName
    )

    $encodedReferenceName = [uri]::EscapeDataString($ReferenceName)
    return Invoke-Ado -Url "$Org/_apis/work/processes/$ResolvedProcessId/workItemTypes/$encodedReferenceName/fields?api-version=7.1" -Token $Pat
}

function Get-WorkItemTypeStates {
    param(
        [Parameter(Mandatory)][string]$ResolvedProcessId,
        [Parameter(Mandatory)][string]$ReferenceName
    )

    $encodedReferenceName = [uri]::EscapeDataString($ReferenceName)
    return Invoke-Ado -Url "$Org/_apis/work/processes/$ResolvedProcessId/workItemTypes/$encodedReferenceName/states?api-version=7.1" -Token $Pat
}

function Get-WorkItemTypeLayout {
    param(
        [Parameter(Mandatory)][string]$ResolvedProcessId,
        [Parameter(Mandatory)][string]$ReferenceName
    )

    $encodedReferenceName = [uri]::EscapeDataString($ReferenceName)
    return Invoke-Ado -Url "$Org/_apis/work/processes/$ResolvedProcessId/workItemTypes/$encodedReferenceName/layout?api-version=7.1" -Token $Pat
}

function New-LayoutControlBody {
    param([Parameter(Mandatory)][object]$SourceControl)

    $controlBody = @{
        id = $SourceControl.id
        label = Get-ObjectProperty -InputObject $SourceControl -Name "label" -Default ""
        controlType = Get-ObjectProperty -InputObject $SourceControl -Name "controlType" -Default "FieldControl"
        readOnly = Get-ObjectProperty -InputObject $SourceControl -Name "readOnly" -Default $false
        visible = Get-ObjectProperty -InputObject $SourceControl -Name "visible" -Default $true
    }
    Add-OptionalProperty -Target $controlBody -Source $SourceControl -Name "order"
    Add-OptionalProperty -Target $controlBody -Source $SourceControl -Name "watermark"
    Add-OptionalProperty -Target $controlBody -Source $SourceControl -Name "metadata"
    Add-OptionalProperty -Target $controlBody -Source $SourceControl -Name "height"

    return $controlBody
}

function Add-LayoutGroup {
    param(
        [Parameter(Mandatory)][string]$ResolvedProcessId,
        [Parameter(Mandatory)][string]$ReferenceName,
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$SectionId,
        [Parameter(Mandatory)][object]$SourceGroup,
        [object[]]$InitialControls = @(),
        [string]$LabelOverride
    )

    $encodedReferenceName = [uri]::EscapeDataString($ReferenceName)
    $encodedPageId = [uri]::EscapeDataString($PageId)
    $encodedSectionId = [uri]::EscapeDataString($SectionId)
    $groupLabel = if ([string]::IsNullOrWhiteSpace($LabelOverride)) { $SourceGroup.label } else { $LabelOverride }
    $groupBody = @{
        label = $groupLabel
        visible = Get-ObjectProperty -InputObject $SourceGroup -Name "visible" -Default $true
    }
    Add-OptionalProperty -Target $groupBody -Source $SourceGroup -Name "order"
    if ($InitialControls.Count -gt 0) {
        $groupBody.controls = @($InitialControls | ForEach-Object { New-LayoutControlBody -SourceControl $_ })
    }

    return Invoke-Ado -Url "$Org/_apis/work/processes/$ResolvedProcessId/workItemTypes/$encodedReferenceName/layout/pages/$encodedPageId/sections/$encodedSectionId/groups?api-version=7.1" -Token $Pat -Method "POST" -Body $groupBody
}

function Add-LayoutControl {
    param(
        [Parameter(Mandatory)][string]$ResolvedProcessId,
        [Parameter(Mandatory)][string]$ReferenceName,
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][object]$SourceControl
    )

    $encodedReferenceName = [uri]::EscapeDataString($ReferenceName)
    $encodedGroupId = [uri]::EscapeDataString($GroupId)
    $controlBody = New-LayoutControlBody -SourceControl $SourceControl

    return Invoke-Ado -Url "$Org/_apis/work/processes/$ResolvedProcessId/workItemTypes/$encodedReferenceName/layout/groups/$encodedGroupId/controls?api-version=7.1" -Token $Pat -Method "POST" -Body $controlBody
}

function Get-LayoutFieldControlIds {
    param([Parameter(Mandatory)]$Layout)

    $controlIds = New-Object System.Collections.Generic.List[string]
    foreach ($page in @($Layout.pages)) {
        foreach ($section in @($page.sections)) {
            foreach ($group in @($section.groups)) {
                foreach ($control in @($group.controls)) {
                    $controlId = Get-ObjectProperty -InputObject $control -Name "id"
                    if ($controlId) {
                        $controlIds.Add($controlId)
                    }
                }
            }
        }
    }

    return @($controlIds)
}

function Find-LayoutPage {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)]$SourcePage
    )

    $sourcePageId = Get-ObjectProperty -InputObject $SourcePage -Name "id"
    $sourcePageLabel = Get-ObjectProperty -InputObject $SourcePage -Name "label"
    $sourcePageType = Get-ObjectProperty -InputObject $SourcePage -Name "pageType"

    $match = @($Layout.pages) | Where-Object { (Get-ObjectProperty -InputObject $_ -Name "id") -eq $sourcePageId } | Select-Object -First 1
    if (-not $match) {
        $match = @($Layout.pages) | Where-Object {
            (Get-ObjectProperty -InputObject $_ -Name "label") -eq $sourcePageLabel -and
            (Get-ObjectProperty -InputObject $_ -Name "pageType") -eq $sourcePageType
        } | Select-Object -First 1
    }

    return $match
}

function Find-LayoutSection {
    param(
        [Parameter(Mandatory)]$TargetPage,
        [Parameter(Mandatory)]$SourceSection
    )

    $sourceSectionId = Get-ObjectProperty -InputObject $SourceSection -Name "id"
    return @($TargetPage.sections) | Where-Object { (Get-ObjectProperty -InputObject $_ -Name "id") -eq $sourceSectionId } | Select-Object -First 1
}

function Find-LayoutGroup {
    param(
        [Parameter(Mandatory)]$TargetSection,
        [Parameter(Mandatory)]$SourceGroup
    )

    $sourceGroupId = Get-ObjectProperty -InputObject $SourceGroup -Name "id"
    $sourceGroupLabel = Get-ObjectProperty -InputObject $SourceGroup -Name "label"

    $match = @($TargetSection.groups) | Where-Object { (Get-ObjectProperty -InputObject $_ -Name "id") -eq $sourceGroupId } | Select-Object -First 1
    if (-not $match) {
        $match = @($TargetSection.groups) | Where-Object { (Get-ObjectProperty -InputObject $_ -Name "label") -eq $sourceGroupLabel } | Select-Object -First 1
    }

    return $match
}

Write-Host "`n=== Clone ADO Work Item Type ===" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "  [WHAT-IF MODE - no changes will be made]" -ForegroundColor Yellow
}

Write-Host "`n[1/4] Resolving process..." -ForegroundColor Yellow
$process = Resolve-Process
Write-Host "  Process: $($process.name) (id: $($process.typeId))" -ForegroundColor Cyan

Write-Host "`n[2/4] Resolving work item types..." -ForegroundColor Yellow
$workItemTypes = Get-WorkItemTypes -ResolvedProcessId $process.typeId
$sourceType = Find-WorkItemType -WorkItemTypes $workItemTypes -NameOrReferenceName $SourceWorkItemType
if (-not $sourceType) {
    throw "Source work item type '$SourceWorkItemType' was not found in process '$($process.name)'."
}

$existingNewType = Find-WorkItemType -WorkItemTypes $workItemTypes -NameOrReferenceName $NewWorkItemTypeName

Write-Host "  Source: $($sourceType.name) ($($sourceType.referenceName))" -ForegroundColor Cyan
Write-Host "  New   : $NewWorkItemTypeName" -ForegroundColor Cyan
if ($existingNewType) {
    Write-Host "  Target already exists: $($existingNewType.name) ($($existingNewType.referenceName))" -ForegroundColor Gray
}

Write-Host "`n[3/4] Creating cloned work item type..." -ForegroundColor Yellow

$color = Get-ObjectProperty -InputObject $sourceType -Name "color" -Default "e87025"
$icon = Get-ObjectProperty -InputObject $sourceType -Name "icon" -Default "icon_list"
$description = $NewDescription
if ([string]::IsNullOrWhiteSpace($description)) {
    $sourceDescription = Get-ObjectProperty -InputObject $sourceType -Name "description" -Default ""
    if ([string]::IsNullOrWhiteSpace($sourceDescription)) {
        $description = "Cloned from $($sourceType.name)."
    }
    else {
        $description = $sourceDescription
    }
}

$createBody = @{
    name = $NewWorkItemTypeName
    description = $description
    color = $color.TrimStart('#')
    icon = $icon
    isDisabled = $false
}

$newType = $null
$createdNewType = $false
if ($existingNewType) {
    $newType = $existingNewType
    Write-Host "  [SKIP] Work item type already exists" -ForegroundColor Gray
}
elseif ($PSCmdlet.ShouldProcess("$($process.name) / $NewWorkItemTypeName", "Create work item type cloned from $($sourceType.name)")) {
    $newType = Invoke-Ado -Url "$Org/_apis/work/processes/$($process.typeId)/workItemTypes?api-version=7.1" -Token $Pat -Method "POST" -Body $createBody
    if (-not $newType) {
        throw "Azure DevOps did not return a work item type after creating '$NewWorkItemTypeName'."
    }

    if (-not (Get-ObjectProperty -InputObject $newType -Name "referenceName")) {
        $workItemTypes = Get-WorkItemTypes -ResolvedProcessId $process.typeId
        $newType = Find-WorkItemType -WorkItemTypes $workItemTypes -NameOrReferenceName $NewWorkItemTypeName
    }

    Write-Host "  Created: $($newType.name) ($($newType.referenceName))" -ForegroundColor Green
    $createdNewType = $true
}
else {
    $newType = [pscustomobject]@{
        name = $NewWorkItemTypeName
        referenceName = "<created-after-apply>"
    }
    Write-Host "  [WOULD CREATE] $NewWorkItemTypeName from $($sourceType.name)" -ForegroundColor Yellow
}

Write-Host "`n[4/4] Copying fields, layout controls, and states..." -ForegroundColor Yellow

$sourceFields = Get-WorkItemTypeFields -ResolvedProcessId $process.typeId -ReferenceName $sourceType.referenceName
$targetFieldRefs = @()
if ((Get-ObjectProperty -InputObject $newType -Name "referenceName") -and (Get-ObjectProperty -InputObject $newType -Name "referenceName") -ne "<created-after-apply>") {
    $targetFields = Get-WorkItemTypeFields -ResolvedProcessId $process.typeId -ReferenceName $newType.referenceName
    $targetFieldRefs = @($targetFields.value | ForEach-Object { $_.referenceName } | Where-Object { $_ })
}

$copyableSourceFields = @($sourceFields.value | Where-Object {
    $fieldRef = Get-ObjectProperty -InputObject $_ -Name "referenceName"
    $fieldRef -and $fieldRef -notlike "System.*"
})
$copyableSourceFieldRefs = @($copyableSourceFields | ForEach-Object { Get-ObjectProperty -InputObject $_ -Name "referenceName" } | Where-Object { $_ })

$systemFieldCount = @($sourceFields.value | Where-Object {
    $fieldRef = Get-ObjectProperty -InputObject $_ -Name "referenceName"
    $fieldRef -like "System.*"
}).Count

$fieldsToCopy = @($copyableSourceFields | Where-Object {
    $fieldRef = Get-ObjectProperty -InputObject $_ -Name "referenceName"
    $targetFieldRefs -notcontains $fieldRef
})

$alreadyPresentFieldCount = $copyableSourceFields.Count - $fieldsToCopy.Count
Write-Host "  Source fields: $($sourceFields.value.Count); already present: $alreadyPresentFieldCount; core system skipped: $systemFieldCount; missing to add: $($fieldsToCopy.Count)" -ForegroundColor Gray

$addedFieldCount = 0
$failedFieldCount = 0

foreach ($field in $fieldsToCopy) {
    $fieldRef = Get-ObjectProperty -InputObject $field -Name "referenceName"
    $fieldBody = @{ referenceName = $fieldRef }
    Add-OptionalProperty -Target $fieldBody -Source $field -Name "required"
    Add-OptionalProperty -Target $fieldBody -Source $field -Name "readOnly"
    Add-OptionalProperty -Target $fieldBody -Source $field -Name "defaultValue"
    Add-OptionalProperty -Target $fieldBody -Source $field -Name "allowGroups"

    if ($PSCmdlet.ShouldProcess("$($newType.name) / $fieldRef", "Add field")) {
        try {
            Invoke-Ado -Url "$Org/_apis/work/processes/$($process.typeId)/workItemTypes/$($newType.referenceName)/fields?api-version=7.1" -Token $Pat -Method "POST" -Body $fieldBody | Out-Null
            Write-Host "  [ADD] Field $fieldRef" -ForegroundColor Green
            $addedFieldCount++
        }
        catch {
            $failedFieldCount++
            Write-Warning "  [SKIP] Field $fieldRef could not be added. $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "  [WOULD ADD] Field $fieldRef" -ForegroundColor Yellow
    }
}

if (-not $WhatIfPreference) {
    Write-Host "  Field copy complete: added $addedFieldCount, failed $failedFieldCount, already present $alreadyPresentFieldCount." -ForegroundColor Gray
}

$layoutAddedCount = 0
$layoutFailedCount = 0
$layoutSkippedCount = 0
$targetReferenceName = Get-ObjectProperty -InputObject $newType -Name "referenceName"

if ($targetReferenceName -and $targetReferenceName -ne "<created-after-apply>") {
    Write-Host "  Copying visible form layout controls..." -ForegroundColor Gray
    $sourceLayout = Get-WorkItemTypeLayout -ResolvedProcessId $process.typeId -ReferenceName $sourceType.referenceName
    $targetLayout = Get-WorkItemTypeLayout -ResolvedProcessId $process.typeId -ReferenceName $targetReferenceName
    $targetControlIds = @(Get-LayoutFieldControlIds -Layout $targetLayout)

    foreach ($sourcePage in @($sourceLayout.pages)) {
        $targetPage = Find-LayoutPage -Layout $targetLayout -SourcePage $sourcePage
        if (-not $targetPage) {
            $layoutSkippedCount++
            Write-Warning "  [SKIP] Layout page '$($sourcePage.label)' was not found on $($newType.name)."
            continue
        }

        foreach ($sourceSection in @($sourcePage.sections)) {
            $targetSection = Find-LayoutSection -TargetPage $targetPage -SourceSection $sourceSection
            if (-not $targetSection) {
                $layoutSkippedCount++
                Write-Warning "  [SKIP] Layout section '$($sourceSection.id)' was not found on page '$($targetPage.label)'."
                continue
            }

            foreach ($sourceGroup in @($sourceSection.groups)) {
                $sourceControlsToCopy = @($sourceGroup.controls | Where-Object {
                    $controlId = Get-ObjectProperty -InputObject $_ -Name "id"
                    $controlId -and
                    ($copyableSourceFieldRefs -contains $controlId) -and
                    ($targetControlIds -notcontains $controlId)
                })

                if ($sourceControlsToCopy.Count -eq 0) {
                    continue
                }

                $targetGroup = Find-LayoutGroup -TargetSection $targetSection -SourceGroup $sourceGroup
                $htmlControlsToCopy = @($sourceControlsToCopy | Where-Object { (Get-ObjectProperty -InputObject $_ -Name "controlType") -eq "HtmlFieldControl" })
                $regularControlsToCopy = @($sourceControlsToCopy | Where-Object { (Get-ObjectProperty -InputObject $_ -Name "controlType") -ne "HtmlFieldControl" })

                if ($htmlControlsToCopy.Count -gt 0) {
                    $htmlGroupLabel = if ($targetGroup) { "$($sourceGroup.label) (copied)" } else { $sourceGroup.label }
                    if ($PSCmdlet.ShouldProcess("$($newType.name) / $htmlGroupLabel", "Create layout group with HTML controls")) {
                        try {
                            Add-LayoutGroup -ResolvedProcessId $process.typeId -ReferenceName $targetReferenceName -PageId $targetPage.id -SectionId $targetSection.id -SourceGroup $sourceGroup -InitialControls $htmlControlsToCopy -LabelOverride $htmlGroupLabel | Out-Null
                            Write-Host "  [ADD] Layout group $htmlGroupLabel" -ForegroundColor Green
                            foreach ($htmlControl in $htmlControlsToCopy) {
                                $htmlControlId = Get-ObjectProperty -InputObject $htmlControl -Name "id"
                                Write-Host "  [ADD] Layout control $htmlControlId" -ForegroundColor Green
                                $targetControlIds += $htmlControlId
                                $layoutAddedCount++
                            }
                        }
                        catch {
                            $layoutFailedCount += $htmlControlsToCopy.Count
                            Write-Warning "  [SKIP] HTML layout controls for group '$($sourceGroup.label)' could not be added. $($_.Exception.Message)"
                        }
                    }
                    else {
                        Write-Host "  [WOULD ADD] Layout group $htmlGroupLabel" -ForegroundColor Yellow
                        foreach ($htmlControl in $htmlControlsToCopy) {
                            $htmlControlId = Get-ObjectProperty -InputObject $htmlControl -Name "id"
                            Write-Host "  [WOULD ADD] Layout control $htmlControlId" -ForegroundColor Yellow
                        }
                    }
                }

                if ($regularControlsToCopy.Count -eq 0) {
                    continue
                }

                if (-not $targetGroup) {
                    if ($PSCmdlet.ShouldProcess("$($newType.name) / $($sourceGroup.label)", "Create layout group")) {
                        try {
                            $targetGroup = Add-LayoutGroup -ResolvedProcessId $process.typeId -ReferenceName $targetReferenceName -PageId $targetPage.id -SectionId $targetSection.id -SourceGroup $sourceGroup
                            Write-Host "  [ADD] Layout group $($sourceGroup.label)" -ForegroundColor Green
                        }
                        catch {
                            $layoutFailedCount += $sourceControlsToCopy.Count
                            Write-Warning "  [SKIP] Layout group '$($sourceGroup.label)' could not be created. $($_.Exception.Message)"
                            continue
                        }
                    }
                    else {
                        Write-Host "  [WOULD ADD] Layout group $($sourceGroup.label)" -ForegroundColor Yellow
                        $targetGroup = [pscustomobject]@{ id = "<created-after-apply>"; label = $sourceGroup.label }
                    }
                }

                foreach ($sourceControl in $regularControlsToCopy) {
                    $controlId = Get-ObjectProperty -InputObject $sourceControl -Name "id"
                    if ((Get-ObjectProperty -InputObject $targetGroup -Name "id") -eq "<created-after-apply>") {
                        Write-Host "  [WOULD ADD] Layout control $controlId" -ForegroundColor Yellow
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess("$($newType.name) / $controlId", "Add layout control")) {
                        try {
                            Add-LayoutControl -ResolvedProcessId $process.typeId -ReferenceName $targetReferenceName -GroupId $targetGroup.id -SourceControl $sourceControl | Out-Null
                            Write-Host "  [ADD] Layout control $controlId" -ForegroundColor Green
                            $targetControlIds += $controlId
                            $layoutAddedCount++
                        }
                        catch {
                            $layoutFailedCount++
                            Write-Warning "  [SKIP] Layout control $controlId could not be added. $($_.Exception.Message)"
                        }
                    }
                    else {
                        Write-Host "  [WOULD ADD] Layout control $controlId" -ForegroundColor Yellow
                    }
                }
            }
        }
    }

    if (-not $WhatIfPreference) {
        Write-Host "  Layout copy complete: added $layoutAddedCount, failed $layoutFailedCount, skipped $layoutSkippedCount." -ForegroundColor Gray
    }
}
else {
    Write-Host "  [SKIP] Layout controls can be copied after the work item type exists." -ForegroundColor Gray
}

$sourceStates = Get-WorkItemTypeStates -ResolvedProcessId $process.typeId -ReferenceName $sourceType.referenceName
$targetStateNames = @()
if ((Get-ObjectProperty -InputObject $newType -Name "referenceName") -and (Get-ObjectProperty -InputObject $newType -Name "referenceName") -ne "<created-after-apply>") {
    $targetStates = Get-WorkItemTypeStates -ResolvedProcessId $process.typeId -ReferenceName $newType.referenceName
    $targetStateNames = @($targetStates.value | ForEach-Object { $_.name } | Where-Object { $_ })
}

$statesToCopy = @($sourceStates.value | Where-Object {
    $_.customizationType -eq "custom" -and
    $_.name -and
    ($targetStateNames -notcontains $_.name)
})

foreach ($state in $statesToCopy) {
    $stateBody = @{
        name = $state.name
        color = $state.color
        stateCategory = $state.stateCategory
    }
    Add-OptionalProperty -Target $stateBody -Source $state -Name "order"

    if ($PSCmdlet.ShouldProcess("$($newType.name) / $($state.name)", "Add state")) {
        Invoke-Ado -Url "$Org/_apis/work/processes/$($process.typeId)/workItemTypes/$($newType.referenceName)/states?api-version=7.1" -Token $Pat -Method "POST" -Body $stateBody | Out-Null
        Write-Host "  [ADD] State $($state.name)" -ForegroundColor Green
    }
    else {
        Write-Host "  [WOULD ADD] State $($state.name)" -ForegroundColor Yellow
    }
}

Write-Host "`n=== Clone complete ===" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "Re-run without -WhatIf to create '$NewWorkItemTypeName'." -ForegroundColor Yellow
}
elseif ($createdNewType) {
    Write-Host "Created '$NewWorkItemTypeName' in process '$($process.name)'." -ForegroundColor Green
}
else {
    Write-Host "'$NewWorkItemTypeName' already exists in process '$($process.name)'; missing fields and states are up to date." -ForegroundColor Green
}