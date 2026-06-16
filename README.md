# ADO Backlog Migration

Scripts for migrating an Azure DevOps backlog — including process customisations, work items, and area/iteration paths — from one organisation to another.

## Overview

| Script | Purpose |
|---|---|
| `migrate-process.ps1` | Migrates process customisations (custom WITs, fields, states) to the target org **before** work items are moved |
| `run-migration.ps1` | Installs and runs [nkdAgility Azure DevOps Migration Tools](https://nkdagility.com/learn/azure-devops-migration-tools/) to migrate work items and area/iteration paths |
| `configuration.json` | Config file for `run-migration.ps1` — defines source/target endpoints, WIQL query, and processor settings |
| `userMapping.json` | Maps source user email addresses to target user email addresses |

---

## Prerequisites

| Requirement | Details |
|---|---|
| .NET 8 SDK | [Download](https://dotnet.microsoft.com/download) — required by `run-migration.ps1` |
| PowerShell 7+ | Recommended; Windows PowerShell 5.1 also works |
| PAT token — source org | Scopes: **Work Items (Read)**, **Project and Team (Read)**, **Process (Read)** |
| PAT token — target org | Scopes: **Work Items (Read & Write)**, **Project and Team (Read)**, **Process (Read & Write)** |
| Inherited process | Both projects must use an **Inherited** process (Agile, Scrum, or CMMI-based). XML / Hosted-XML processes are not supported by the API |

---

## Recommended Migration Order

```
Step 1 — Migrate process customisations (migrate-process.ps1)
Step 2 — Migrate work items & area/iteration paths (run-migration.ps1)
```

Always run each script with its dry-run / what-if flag first.

---

## Step 1 — `migrate-process.ps1`

Migrates process-level customisations from the source organisation to the target using the ADO Inherited Process REST API. Run this **before** migrating work items so that all custom fields exist on the target.

### What it migrates

| # | What |
|---|---|
| 1/5 | Discovers the inherited process used by each project |
| 2/5 | Creates custom **work item types** missing on the target |
| 3/5 | Creates custom **fields** at the process level |
| 4/5 | Adds custom fields to the matching **work item types** |
| 5/5 | Creates custom **workflow states** on each work item type |

### Limitations

- Custom WIT backlog/board behaviour (levels, colour rules) is not migrated.
- Field form layout/positions are not migrated — fields appear in the default section.
- System fields (`System.*`) and VSTS fields (`Microsoft.VSTS.*`) are skipped — they always exist.

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `-SourceOrg` | Yes | Source org URL, e.g. `https://dev.azure.com/old-org` |
| `-SourceProject` | Yes | Source project name |
| `-SourcePat` | Yes | Source PAT token |
| `-TargetOrg` | Yes | Target org URL |
| `-TargetProject` | Yes | Target project name |
| `-TargetPat` | Yes | Target PAT token |
| `-WhatIf` | No | Preview changes without making them |

### Usage

**Dry-run (preview only):**
```powershell
.\migrate-process.ps1 `
    -SourceOrg    "https://dev.azure.com/old-org" `
    -SourceProject "MyProject" `
    -SourcePat    "source-pat-here" `
    -TargetOrg    "https://dev.azure.com/new-org" `
    -TargetProject "MyProject" `
    -TargetPat    "target-pat-here" `
    -WhatIf
```

**Apply changes:**
```powershell
.\migrate-process.ps1 `
    -SourceOrg    "https://dev.azure.com/old-org" `
    -SourceProject "MyProject" `
    -SourcePat    "source-pat-here" `
    -TargetOrg    "https://dev.azure.com/new-org" `
    -TargetProject "MyProject" `
    -TargetPat    "target-pat-here"
```

---

## Step 2 — `run-migration.ps1`

Installs the [nkdAgility Azure DevOps Migration Tools](https://nkdagility.com/learn/azure-devops-migration-tools/) .NET global tool and runs it using `configuration.json`. Migrates:

- Work items (Epics, Features, User Stories, Tasks, Bugs, Issues) with full revision history
- Area paths and iteration paths

### Before running

1. **Edit `configuration.json`** — replace all placeholder values:

   | Placeholder | Replace with |
   |---|---|
   | `SOURCE-ORG` | Source organisation name |
   | `SOURCE-PROJECT` | Source project name |
   | `SOURCE_PAT_TOKEN_HERE` | Source PAT token |
   | `TARGET-ORG` | Target organisation name |
   | `TARGET-PROJECT` | Target project name |
   | `TARGET_PAT_TOKEN_HERE` | Target PAT token |

2. **Add the `ReflectedWorkItemId` custom field** to both organisations (required by the migration tool to track already-migrated items and prevent duplicates):
   - Go to `https://dev.azure.com/<org>/_settings/process`
   - Open the Agile process → each work item type (Epic, Feature, User Story, Task, Bug, Issue)
   - Add field: **Name** = `ReflectedWorkItemId`, **Type** = Text (single line)

3. **(Optional) Edit `userMapping.json`** — add source → target email mappings if users have different addresses in the new org. Then set `"Enabled": true` for `TfsUserMappingTool` in `configuration.json`.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-DryRun` | false | Validate config without making any changes |
| `-SkipInstall` | false | Skip the tool install/update step |
| `-ConfigFile` | `.\configuration.json` | Path to the migration tool config file |

### Usage

**Dry-run (validates config and connectivity):**
```powershell
.\run-migration.ps1 -DryRun
```

**Migrate (prompts for confirmation before running):**
```powershell
.\run-migration.ps1
```

**Use a different config file:**
```powershell
.\run-migration.ps1 -ConfigFile ".\my-config.json"
```

**Skip tool re-installation (faster on subsequent runs):**
```powershell
.\run-migration.ps1 -SkipInstall
```

Logs are written to `.\logs\migration-<date>.log`.

---

## `configuration.json` — Key settings

| Setting | Description |
|---|---|
| `ReplayRevisions` | `true` — migrates full item history, not just the latest state |
| `CollapseRevisions` | `false` — keep `true` only if you don't need history (speeds up large migrations) |
| `FilterWorkItemsThatAlreadyExistInTarget` | `true` — safe to re-run; already-migrated items are skipped |
| `UpdateCreatedDate` / `UpdateCreatedBy` | `true` — preserves original created date and author |
| `SkipRevisionWithInvalidIterationPath` | `true` — prevents failures if an iteration path is missing on target |
| `WIQLQuery` | WIQL filter controlling which items are migrated; edit to scope by area path or date |

### Migrating a subset of items

Edit the `WIQLQuery` in `configuration.json` to restrict by area path:

```sql
SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.AreaPath] UNDER 'MyProject\TeamA'
  AND [System.WorkItemType] NOT IN ('Test Suite', 'Test Plan')
ORDER BY [System.ChangedDate] desc
```

Or migrate in batches using `NodeBasePaths` on the `WorkItemMigrationProcessor`:

```json
"NodeBasePaths": ["MyProject\\TeamA", "MyProject\\TeamB"]
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `'devopsmigration' command not found` | Add `~/.dotnet/tools` to your `PATH`, or restart the terminal after install |
| `Connection FAILED` on validation | Check the org URL ends with `/`, project name is exact, and PAT has correct scopes |
| `ReflectedWorkItemId field not found` | Add the custom field to both process templates (see Step 2 above) |
| Items migrated but assigned to wrong user | Populate `userMapping.json` and enable `TfsUserMappingTool` in `configuration.json` |
| Process migration fails with `isSystem` warning | Your org uses XML/Hosted-XML process — `migrate-process.ps1` is not supported; recreate customisations manually |
| Large migration is slow | Set `CollapseRevisions: true` to skip history replay, or scope `NodeBasePaths` to migrate in batches |
