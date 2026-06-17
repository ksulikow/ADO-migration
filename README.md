# ADO Backlog Migration

Scripts for cloning Azure DevOps work item types inside an inherited process and migrating backlog items into the cloned types.

## Overview

| Script | Purpose |
|---|---|
| `clone-workitem-type.ps1` | Clones a work item type inside the same inherited process with a new name |
| `run-migration.ps1` | Installs and runs [nkdAgility Azure DevOps Migration Tools](https://nkdagility.com/learn/azure-devops-migration-tools/) to migrate the scoped work items |
| `configuration.json` | Config file for `run-migration.ps1`; currently maps `User Story` to `User Story New` and `Feature` to `Feature New` |
| `userMapping.json` | Maps source user email addresses to target user email addresses |

---

## Prerequisites

| Requirement | Details |
|---|---|
| winget | Required by `run-migration.ps1` when `-SkipInstall` is not used |
| .NET 8 SDK | [Download](https://dotnet.microsoft.com/download) - required by the migration tool |
| PowerShell 7+ | Recommended; Windows PowerShell 5.1 also works |
| PAT token | Scopes: **Work Items (Read & Write)**, **Project and Team (Read)**, **Process (Read & Write)** |
| Inherited process | The project must use an **Inherited** process. XML / Hosted-XML processes are not supported by the process APIs |

---

## Recommended Order

```
Step 1 — Clone User Story to User Story New
Step 2 — Clone Feature to Feature New
Step 3 — Validate configuration.json
Step 4 — Run the scoped work item migration
```

Always run clone commands with `-WhatIf` first and run `run-migration.ps1 -DryRun` before live migration.

---

## `clone-workitem-type.ps1` Reference

Clones an existing work item type within the same inherited process using a new name. You can identify the process by project, process name, or process ID.

### What it copies

| What | Notes |
|---|---|
| Work item type | Creates a new custom work item type using the source type's metadata |
| Custom fields | Adds non-system fields from the source type where they are not already inherited |
| Form controls | Adds visible field controls to matching form groups so copied fields appear in the UI |
| Custom states | Copies custom workflow states from the source type |

### Limitations

- Only works with **Inherited** processes. XML / Hosted-XML processes are not supported by the API.
- Visible field controls are copied into matching form groups. HTML field controls, such as Acceptance Criteria, are copied into a new group when Azure DevOps does not allow adding them to an existing group. Pages and sections must already exist on the target work item type.
- Backlog levels, board behaviour, and rules are not copied.
- Core system fields (`System.*`) are skipped because Azure DevOps manages them. Built-in process fields such as `Microsoft.VSTS.*` are copied when the API allows them.

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `-Org` | Yes | Org URL, e.g. `https://dev.azure.com/my-org` |
| `-Pat` | Yes | PAT token with **Process (Read & Write)** and **Project and Team (Read)** |
| `-Project` | One selector required | Project whose inherited process should be used |
| `-ProcessName` | One selector required | Process name to use instead of `-Project` |
| `-ProcessId` | One selector required | Process type ID to use instead of `-Project` |
| `-SourceWorkItemType` | Yes | Source type name or reference name, e.g. `User Story` |
| `-NewWorkItemTypeName` | Yes | Name for the cloned work item type |
| `-NewDescription` | No | Description for the cloned type |
| `-WhatIf` | No | Preview changes without making them |

### Usage

**Dry-run (preview only):**
```powershell
.\clone-workitem-type.ps1 `
  -Org "https://dev.azure.com/my-org" `
  -Project "MyProject" `
  -Pat "pat-here" `
  -SourceWorkItemType "User Story" `
  -NewWorkItemTypeName "Partner Story" `
  -WhatIf
```

**Apply changes:**
```powershell
.\clone-workitem-type.ps1 `
  -Org "https://dev.azure.com/my-org" `
  -Project "MyProject" `
  -Pat "pat-here" `
  -SourceWorkItemType "User Story" `
  -NewWorkItemTypeName "Partner Story"
```

---

## Step 1 — Clone the work item types

Use `clone-workitem-type.ps1` to create the target work item types in the same inherited process before migrating work items.

**Preview User Story clone:**
```powershell
.\clone-workitem-type.ps1 `
  -Org "https://dev.azure.com/Kriss365-Dev" `
  -ProcessName "test" `
  -Pat "pat-here" `
  -SourceWorkItemType "User Story" `
  -NewWorkItemTypeName "User Story New" `
  -WhatIf
```

**Create User Story New:**
```powershell
.\clone-workitem-type.ps1 `
  -Org "https://dev.azure.com/Kriss365-Dev" `
  -ProcessName "test" `
  -Pat "pat-here" `
  -SourceWorkItemType "User Story" `
  -NewWorkItemTypeName "User Story New"
```

**Create Feature New:**
```powershell
.\clone-workitem-type.ps1 `
  -Org "https://dev.azure.com/Kriss365-Dev" `
  -ProcessName "test" `
  -Pat "pat-here" `
  -SourceWorkItemType "Feature" `
  -NewWorkItemTypeName "Feature New"
```

The clone script is safe to re-run. If the target type already exists, it skips creation and adds any missing fields, visible layout controls, and custom states that can be copied by the Azure DevOps process API.

---

## Step 2 — `run-migration.ps1`

Installs the [nkdAgility Azure DevOps Migration Tools](https://nkdagility.com/learn/azure-devops-migration-tools/) tool and runs it using `configuration.json`.

The current config is scoped to migrate only source `User Story` and `Feature` work items, then create the migrated copies as `User Story New` and `Feature New`.

### Before running

1. **Edit `configuration.json`** — set the endpoint and token values:

    | Setting | Description |
   |---|---|
    | `MigrationTools.Endpoints.Source.Collection` | Source Azure DevOps organisation URL |
    | `MigrationTools.Endpoints.Source.Project` | Source project name |
    | `MigrationTools.Endpoints.Source.Authentication.AccessToken` | Source PAT token |
    | `MigrationTools.Endpoints.Target.Collection` | Target Azure DevOps organisation URL |
    | `MigrationTools.Endpoints.Target.Project` | Target project name |
    | `MigrationTools.Endpoints.Target.Authentication.AccessToken` | Target PAT token |

2. **Add the `ReflectedWorkItemId` custom field** to the source and target work item types used by the migration tool. This field tracks already-migrated items and prevents duplicates.
   - Go to `https://dev.azure.com/<org>/_settings/process`
  - Open the inherited process, then the relevant work item types
   - Add field: **Name** = `ReflectedWorkItemId`, **Type** = Text (single line)
  - For this config, make sure it exists on `User Story`, `User Story New`, `Feature`, and `Feature New`

3. **(Optional) Edit `userMapping.json`** if users have different addresses in the target project. The current `configuration.json` does not enable user mapping, so add and enable the migration tool's user mapping tool before relying on this file.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-DryRun` | false | Validate config and connectivity without running `devopsmigration execute` |
| `-SkipInstall` | false | Skip the tool install/update step |
| `-ConfigFile` | `.\configuration.json` | Path to the migration tool config file |

### Usage

**Dry-run (validates config and connectivity only):**
```powershell
.\run-migration.ps1 -DryRun
```

`devopsmigration` v16.3.3 does not expose an `execute --dryRun` option, so this wrapper intentionally stops before invoking the migration command.

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

The script creates `.\logs` for migration output. The current `configuration.json` writes migration tool output to the console; add a Serilog file sink if you want file logs.

---

## `configuration.json` — Key settings

| Setting | Description |
|---|---|
| `WIQLQuery` | Selects only `User Story` and `Feature` source work items |
| `WorkItemTypeMappingTool` | Maps `User Story` to `User Story New` and `Feature` to `Feature New` |
| `TfsWorkItemTypeValidatorTool.IncludeWorkItemTypes` | Limits validation to `User Story`, `User Story New`, `Feature`, and `Feature New` |
| `ReplayRevisions` | `true` — migrates full item history, not just the latest state |
| `FilterWorkItemsThatAlreadyExistInTarget` | `true` — safe to re-run; already-migrated items are skipped |
| `UpdateCreatedDate` / `UpdateCreatedBy` | `true` — preserves original created date and author |
| `SkipRevisionWithInvalidIterationPath` | `true` — prevents failures if an iteration path is missing on target |

### Migrating a subset of items

Keep the work item type filter in place, and add any extra scope to the `WIQLQuery`, such as an area path:

```sql
SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = @TeamProject
  AND [System.WorkItemType] IN ('User Story', 'Feature')
  AND [System.AreaPath] UNDER 'MyProject\TeamA'
ORDER BY [System.ChangedDate] desc
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `'devopsmigration' command not found` | Add `~/.dotnet/tools` to your `PATH`, or restart the terminal after install |
| `Connection FAILED` on validation | Check the org URL ends with `/`, project name is exact, and PAT has correct scopes |
| `ReflectedWorkItemId field not found` | Add the custom field to `User Story`, `User Story New`, `Feature`, and `Feature New` |
| Items migrated with the wrong work item type | Use `WorkItemTypeMappingTool`; do not map `System.WorkItemType` with `FieldMappingTool` |
| `Acceptance Criteria` is missing after cloning | Re-run `clone-workitem-type.ps1`; HTML controls are copied by creating a copied layout group |
| Large migration is slow | Add extra filters to `WIQLQuery`, such as area path or changed date, and run in smaller batches |
