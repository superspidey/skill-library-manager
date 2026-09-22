import fs from 'node:fs/promises'
import path from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const parseArgs = () => {
  const args = new Map()
  for (let index = 2; index < process.argv.length; index += 1) {
    const token = process.argv[index]
    if (!token.startsWith('--')) continue
    const next = process.argv[index + 1]
    if (next && !next.startsWith('--')) {
      args.set(token.slice(2), next)
      index += 1
    } else {
      args.set(token.slice(2), true)
    }
  }
  return args
}

const normalizeRows = (data) => {
  const rows = Array.isArray(data) ? data : data?.rows
  if (!Array.isArray(rows)) throw new Error('Rows JSON must be an array or an object with a rows array.')
  return rows.map((row) => ({
    name: String(row?.name ?? '').trim(),
    description: String(row?.description ?? '').trim(),
    usageScenario: String(row?.usageScenario ?? '').trim(),
  })).filter((row) => row.name)
}

const loadArtifactTool = async () => {
  const nodeModulesRoot = process.env.ARTIFACT_TOOL_NODE_MODULES
  if (!nodeModulesRoot) {
    throw new Error('Set ARTIFACT_TOOL_NODE_MODULES from load_workspace_dependencies before running this script.')
  }
  const requireFromRuntime = createRequire(path.join(nodeModulesRoot, 'package.json'))
  const entryPath = requireFromRuntime.resolve('@oai/artifact-tool')
  return import(pathToFileURL(entryPath).href)
}

const args = parseArgs()
const catalogArg = args.get('catalog')
const rowsArg = args.get('rows')
if (!catalogArg || !rowsArg) throw new Error('Both --catalog and --rows are required.')
const catalogPath = path.resolve(String(catalogArg))
const rowsPath = path.resolve(String(rowsArg))

const requestedRows = normalizeRows(JSON.parse(await fs.readFile(rowsPath, 'utf8')))
for (const row of requestedRows) {
  if (!row.description || !row.usageScenario) {
    throw new Error(`Row '${row.name}' must include description and usageScenario.`)
  }
}
const requestedNames = requestedRows.map((row) => row.name)
if (new Set(requestedNames).size !== requestedNames.length) {
  throw new Error('Rows JSON contains duplicate skill names.')
}

const { FileBlob, SpreadsheetFile } = await loadArtifactTool()
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(catalogPath))
const sheet = workbook.worksheets.getFirst()
const used = sheet.getUsedRange()
const values = used.values.map((row) => row.map((value) => (value == null ? '' : String(value).trim())))
const expectedHeaders = ['Skill 名称', '说明', '使用场景']
if (JSON.stringify((values[0] ?? []).slice(0, 3)) !== JSON.stringify(expectedHeaders)) {
  throw new Error(`Unexpected headers: ${JSON.stringify((values[0] ?? []).slice(0, 3))}`)
}

const existingNames = new Set(values.slice(1).map((row) => row[0]).filter(Boolean))
for (const row of values.slice(1).filter((row) => row[0])) {
  if (existingNames.has(row[0]) && values.slice(1).filter((candidate) => candidate[0] === row[0]).length > 1) {
    throw new Error(`Catalog contains duplicate skill name: ${row[0]}`)
  }
}

const rowsToAdd = requestedRows.filter((row) => !existingNames.has(row.name))
if (rowsToAdd.length === 0) {
  process.stdout.write(`${JSON.stringify({ catalogPath, added: 0, skipped: requestedRows.length, verified: true }, null, 2)}\n`)
  process.exit(0)
}

const existingDataCount = values.slice(1).filter((row) => row[0]).length
const firstDataRow = used.rowIndex + existingDataCount + 2
const startIndex = firstDataRow - 1
if (firstDataRow !== existingDataCount + 2) {
  throw new Error('Unable to determine the append row safely.')
}
const appendRange = sheet.getRangeByIndexes(startIndex, 0, rowsToAdd.length, 3)
appendRange.values = rowsToAdd.map((row) => [row.name, row.description, row.usageScenario])

const border = {
  insideHorizontal: { style: 'thin', color: '#E5E7EB' },
  top: { style: 'thin', color: '#D7DEE8' },
  bottom: { style: 'thin', color: '#D7DEE8' },
  left: { style: 'thin', color: '#D7DEE8' },
  right: { style: 'thin', color: '#D7DEE8' },
}

for (let index = 0; index < rowsToAdd.length; index += 1) {
  const row = rowsToAdd[index]
  const rowNumber = firstDataRow + index
  const estimatedLines = Math.max(1, Math.ceil(Math.max(row.description.length, row.usageScenario.length) / 43))
  const rowRange = sheet.getRange(`A${rowNumber}:C${rowNumber}`)
  rowRange.format = {
    fill: rowNumber % 2 === 0 ? '#FFFFFF' : '#F7F9FC',
    font: { name: 'Microsoft YaHei', size: 11, color: '#1F2937' },
    verticalAlignment: 'center',
    wrapText: true,
    rowHeight: Math.max(42, 20 + estimatedLines * 18),
    borders: border,
  }
  sheet.getRange(`A${rowNumber}:A${rowNumber}`).format.font = {
    name: 'Microsoft YaHei',
    size: 11,
    bold: true,
    color: '#1F2937',
  }
}

workbook.recalculate()
const lastRow = firstDataRow + rowsToAdd.length - 1
await workbook.inspect({
  kind: 'table',
  range: `A1:C${lastRow}`,
  include: 'values',
  tableMaxRows: lastRow,
  tableMaxCols: 3,
})
await workbook.inspect({
  kind: 'match',
  searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!|#NULL!|#SPILL!|#CALC!',
  options: { useRegex: true, maxResults: 100 },
  summary: 'formula error scan',
})

const previewPath = args.get('preview') ? path.resolve(String(args.get('preview'))) : null
if (previewPath) {
  const preview = await workbook.render({
    sheetName: sheet.name,
    range: `A1:C${lastRow}`,
    scale: 2,
    format: 'png',
  })
  await fs.mkdir(path.dirname(previewPath), { recursive: true })
  await fs.writeFile(previewPath, new Uint8Array(await preview.arrayBuffer()))
}

const output = await SpreadsheetFile.exportXlsx(workbook)
const stamp = new Date().toISOString().replace(/[:.]/g, '-')
const tempPath = path.join(path.dirname(catalogPath), `.${path.basename(catalogPath)}.${stamp}.tmp.xlsx`)
const backupPath = path.join(path.dirname(catalogPath), `${path.basename(catalogPath, '.xlsx')}.${stamp}.bak.xlsx`)
const swapPath = path.join(path.dirname(catalogPath), `.${path.basename(catalogPath)}.${stamp}.swap.xlsx`)
await output.save(tempPath)
await fs.copyFile(catalogPath, backupPath)

let swapped = false
try {
  await fs.rename(catalogPath, swapPath)
  await fs.rename(tempPath, catalogPath)
  swapped = true
  await fs.rm(swapPath, { force: true })
} catch (error) {
  if (!swapped && !(await fs.stat(catalogPath).catch(() => null))) {
    await fs.rename(swapPath, catalogPath).catch(() => {})
  }
  throw error
}

const verifyWorkbook = await SpreadsheetFile.importXlsx(await FileBlob.load(catalogPath))
const verifySheet = verifyWorkbook.worksheets.getFirst()
const verifyValues = verifySheet.getUsedRange().values
const verifyRows = verifyValues.slice(1).filter((row) => row[0])
const verifyNames = verifyRows.map((row) => String(row[0]).trim())
if (verifyRows.length !== values.slice(1).filter((row) => row[0]).length + rowsToAdd.length) {
  throw new Error('Saved catalog row count verification failed.')
}
if (new Set(verifyNames).size !== verifyNames.length) {
  throw new Error('Saved catalog contains duplicate names.')
}
for (const row of rowsToAdd) {
  if (verifyNames.filter((name) => name === row.name).length !== 1) {
    throw new Error(`Saved catalog does not contain '${row.name}' exactly once.`)
  }
}

process.stdout.write(`${JSON.stringify({
  catalogPath,
  backupPath,
  previewPath,
  added: rowsToAdd.length,
  skipped: requestedRows.length - rowsToAdd.length,
  totalRows: verifyRows.length,
  verified: true,
}, null, 2)}\n`)



