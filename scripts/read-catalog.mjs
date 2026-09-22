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
if (!catalogArg) {
  throw new Error('Missing --catalog.')
}
const catalogPath = path.resolve(String(catalogArg))
await fs.access(catalogPath)

const { FileBlob, SpreadsheetFile } = await loadArtifactTool()
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(catalogPath))
const sheet = workbook.worksheets.getFirst()
const used = sheet.getUsedRange()
const values = used.values.map((row) => row.map((value) => (value == null ? '' : String(value).trim())))
const headers = values[0] ?? []
const expectedHeaders = ['Skill 名称', '说明', '使用场景']
if (JSON.stringify(headers.slice(0, 3)) !== JSON.stringify(expectedHeaders)) {
  throw new Error(`Unexpected headers: ${JSON.stringify(headers.slice(0, 3))}`)
}

const rows = values
  .slice(1)
  .filter((row) => row[0])
  .map((row) => ({ name: row[0], description: row[1] ?? '', usageScenario: row[2] ?? '' }))

if (new Set(rows.map((row) => row.name)).size !== rows.length) {
  throw new Error('The catalog contains duplicate skill names.')
}

if (args.has('names-only')) {
  process.stdout.write(`${JSON.stringify(rows.map((row) => row.name), null, 2)}\n`)
} else {
  process.stdout.write(`${JSON.stringify({ catalogPath, sheetName: sheet.name, headers: expectedHeaders, rows }, null, 2)}\n`)
}

