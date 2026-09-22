# Skill Library Manager

一个面向 Windows Codex 的 Skill 资产整理工具。它把用户级外部 skill 统一移到
`D:\ALL skills`，在原路径建立 Junction，并把 skill 名称、说明和使用场景增量写入 Excel。

## 解决的问题

- 多个 skill 分散在 `.codex\skills` 和 `.agents\skills`，不利于统一管理和备份。
- 直接移动后会破坏 Codex 的 skill 发现路径。
- 重复执行迁移脚本可能误移动已经归档的 skill。
- 每次手工重写 Excel 容易丢失旧记录、格式和历史内容。

## 核心规则

1. 先读取现有 Excel，提取已经完成的 skill 名称。
2. 已完成的 skill 只校验状态，不再次移动。
3. 只迁移 Excel 中不存在、且位于用户 skill 源目录的新 skill。
4. 物理目录存放在 `D:\ALL skills\<skill-name>`。
5. 原路径改为指向新目录的 Windows Junction，Codex 使用路径不变。
6. Excel 只追加缺失行，不重建、不排序、不覆盖既有内容。
7. 失败时回滚本轮已完成的移动和联接，避免半完成状态。

默认排除 `.system`、`.npm-cache`、插件缓存以及没有 `SKILL.md` 的目录。

## 安装

把本目录放入 Codex skill 目录，或为它建立 Junction：

```powershell
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.codex\skills\skill-library-manager" `
  -Target "D:\ALL skills\skill-library-manager"
```

重启或重新加载 Codex 后即可调用。

## 使用示例

```text
使用 $skill-library-manager，检查 D:\ALL skills 的 Excel 清单，只处理新安装的外部 skill。
```

```text
使用 $skill-library-manager，继续上次的 skill 归档流程，不要重复移动已经完成的项目。
```

## 工作流

### 1. 读取 Excel 清单

`read-catalog.mjs` 会读出表头、全部行以及已记录的 skill 名称。若表格不存在，按以下表头创建：

| Skill 名称 | 说明 | 使用场景 |
| --- | --- | --- |
| 示例 skill | 该 skill 能做什么 | 什么时候应该使用 |

### 2. 预演增量变更

先只扫描和分类，不修改文件：

```powershell
pwsh -NoProfile -File scripts/manage-skill-library.ps1 `
  -CatalogNamesPath catalog-names.json `
  -RowsPath new-rows.json `
  -ReportPath skill-library-plan.json
```

`new-rows.json` 示例：

```json
[
  {
    "name": "new-skill-name",
    "description": "用于完成某类任务的简短说明。",
    "usageScenario": "用户在什么情况下应该调用它。"
  }
]
```

检查报告中的 `move`、`repair-junction`、`already-complete` 和冲突项。

### 3. 正式迁移

确认预演结果后增加 `-Apply`：

```powershell
pwsh -NoProfile -File scripts/manage-skill-library.ps1 `
  -CatalogNamesPath catalog-names.json `
  -RowsPath new-rows.json `
  -ReportPath skill-library-apply.json `
  -Apply
```

脚本会禁止覆盖已有目标目录；出现冲突时直接停止。

### 4. 追加 Excel 行

`upsert-catalog.mjs` 会按第一列名称去重：

```bash
ARTIFACT_TOOL_NODE_MODULES="<Codex 运行时 node_modules>" \
  node scripts/upsert-catalog.mjs \
  --catalog "D:/ALL skills/external-skill-catalog.xlsx" \
  --rows new-rows.json \
  --preview "skill-catalog-preview.png"
```

脚本会保留原格式，只向末尾追加新行，并在替换前创建带时间戳的备份。

## 目录结构

```text
skill-library-manager/
├── SKILL.md
├── README.md
├── agents/
│   └── openai.yaml
└── scripts/
    ├── manage-skill-library.ps1
    ├── read-catalog.mjs
    └── upsert-catalog.mjs
```

## 安全边界

- 不移动官方内置 skill、插件管理的 skill、`.system` 和 `.npm-cache`。
- 不覆盖目标目录，不递归删除未验证路径。
- 不强制推送，不提交本机状态、凭据或私密路径证据。
- Excel 修改前保留备份；已存在同名行时跳过，而不是覆盖。
- 发现目录、Junction 或 Excel 状态不一致时停止，不猜测修复。

## 验证标准

- 每个迁移项在 `D:\ALL skills` 中有 `SKILL.md`。
- 每个原路径都是指向目标目录的有效 Junction。
- 通过原路径可以读取 `SKILL.md`。
- Excel 中每个 skill 名称只出现一次，原有记录没有减少。
