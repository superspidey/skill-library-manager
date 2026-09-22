---
name: skill-library-manager
description: Incrementally organize user-installed Codex skills into a central Windows skill library, preserve discovery with junctions, and append only new entries to an Excel catalog. Use when the user asks to move or archive external skills, keep skills in D:\ALL skills, update the external skill Excel inventory, repair missing junctions, or repeat the prior skill-relocation workflow without moving already completed skills twice.
metadata:
  short-description: Move skills safely and maintain the Excel catalog
---

# Skill Library Manager

Maintain one physical copy of each user-installed skill under a central library while keeping the original Codex discovery path usable.

Defaults:

- Library root: `D:\ALL skills`
- Excel catalog: `D:\ALL skills\external-skill-catalog.xlsx`
- Source roots: `%USERPROFILE%\.codex\skills` and `%USERPROFILE%\.agents\skills`
- Excel columns: `Skill 名称`, `说明`, `使用场景`

The workflow is incremental and idempotent. Existing catalog rows are authority that a skill was already processed. Never move an already cataloged skill a second time.

## Required behavior

1. Read the existing Excel catalog before touching any skill directory.
2. Scan source roots for direct child directories containing `SKILL.md`.
3. Classify every relevant skill as `already-complete`, `repair-junction`, `move`, or a blocking conflict.
4. Move only new skills that are absent from the catalog and still exist as real directories in a source root.
5. Preserve discovery by creating a Windows directory junction at the original source path.
6. Append only new rows to the Excel catalog. Do not rebuild, reorder, or overwrite existing rows or styles.
7. Verify the migrated skill through both the original path and library path, then verify the final workbook.

Never move `.system`, `.npm-cache`, plugin-managed skills, dependency folders, or directories without `SKILL.md`.

## Workflow

### 1. Discover the current state

Use the bundled spreadsheets workflow for all `.xlsx` operations. `load_workspace_dependencies` returns the Node package root used by the helper scripts.

Run:

```bash
ARTIFACT_TOOL_NODE_MODULES="<dependency_node_modules>" \
  node scripts/read-catalog.mjs \
  --catalog "D:/ALL skills/external-skill-catalog.xlsx" \
  --names-only > catalog-names.json
```

The output is a JSON array of names already recorded in Excel. If the workbook does not exist, create it with the required three headers before continuing.

### 2. Prepare the incremental batch

Scan and classify without changing the filesystem:

```powershell
pwsh -NoProfile -File scripts/manage-skill-library.ps1 `
  -CatalogNamesPath catalog-names.json `
  -RowsPath new-rows.json `
  -ReportPath skill-library-plan.json
```

`new-rows.json` is a JSON array containing only newly discovered skills:

```json
[
  {
    "name": "new-skill-name",
    "description": "What the skill does.",
    "usageScenario": "When the skill should be used."
  }
]
```

Inspect the report before applying. Stop on target conflicts, duplicate names, missing `SKILL.md`, or catalog/filesystem inconsistency. Do not overwrite or merge directories automatically.

### 3. Apply the filesystem changes

Re-run the same command with `-Apply`:

```powershell
pwsh -NoProfile -File scripts/manage-skill-library.ps1 `
  -CatalogNamesPath catalog-names.json `
  -RowsPath new-rows.json `
  -ReportPath skill-library-apply.json `
  -Apply
```

The script moves new real skill directories to `D:\ALL skills`, creates junctions at their original paths, and rolls back completed moves if a later step fails. Cataloged entries with an existing target but missing source junction are repaired without moving the target again.

### 4. Append the catalog rows

Immediately before the first workbook edit, run the spreadsheets skill marker operation. Then append idempotently:

```bash
ARTIFACT_TOOL_NODE_MODULES="<dependency_node_modules>" \
  node scripts/upsert-catalog.mjs \
  --catalog "D:/ALL skills/external-skill-catalog.xlsx" \
  --rows new-rows.json \
  --preview "skill-catalog-preview.png"
```

The helper preserves the existing workbook and skips names already present. It validates the three required headers, appends only missing rows, renders a preview, writes a timestamped backup, and verifies the saved workbook.

### 5. Verify

For every changed skill, confirm:

- `D:\ALL skills\<name>\SKILL.md` exists.
- The original source path is a reparse point/junction.
- `SKILL.md` is readable through the original source path.
- The Excel name exists exactly once.
- Existing catalog row count did not decrease.

Report moved, repaired, skipped, and blocked counts separately.

## Commands

The scripts are deterministic helpers, not a replacement for inspection:

- `scripts/read-catalog.mjs`: read headers, names, and rows from the existing workbook.
- `scripts/manage-skill-library.ps1`: dry-run or apply incremental move/junction changes.
- `scripts/upsert-catalog.mjs`: append missing rows without rebuilding the workbook.

## Safety

- Back up the workbook before replacement and keep the backup local.
- Never overwrite an existing target directory.
- Never remove or merge a source directory automatically.
- Never use recursive deletion on an unresolved or unchecked path.
- Never use `-Force` to bypass conflicts.
- Never publish `TASK_PROGRESS.md`, local evidence, tokens, or machine-specific state.
- Stop and ask when ownership or catalog state is inconsistent.

## 中文说明

该 skill 用于把用户级外部 skill 增量归集到 `D:\ALL skills`，并在原路径创建目录联接以保持 Codex 正常发现和使用。它先读取 Excel 清单，已记录的 skill 只校验、不重复迁移；只处理新 skill，并把新增说明和使用场景追加到原表格，不重建旧内容。
