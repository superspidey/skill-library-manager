[CmdletBinding()]
param(
  [string[]]$SourceRoots = @(
    (Join-Path $env:USERPROFILE '.codex\skills'),
    (Join-Path $env:USERPROFILE '.agents\skills')
  ),
  [string]$TargetRoot = 'D:\ALL skills',
  [Parameter(Mandatory = $true)]
  [string]$CatalogNamesPath,
  [Parameter(Mandatory = $true)]
  [string]$RowsPath,
  [string]$ReportPath = 'skill-library-report.json',
  [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$excludedNames = @('.system', '.npm-cache', 'node_modules')

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "JSON file not found: $Path"
  }

  $raw = Get-Content -Raw -LiteralPath $Path -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @()
  }
  return ConvertFrom-Json -InputObject $raw
}

function Get-ItemIfExists {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Test-ReparsePoint {
  param([Parameter(Mandatory = $true)]$Item)
  return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-SkillDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if (-not (Test-Path -LiteralPath (Join-Path $Directory 'SKILL.md') -PathType Leaf)) {
    throw "$Context is missing SKILL.md: $Directory"
  }
}

function Assert-Junction {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$TargetPath
  )

  $item = Get-ItemIfExists -Path $SourcePath
  if ($null -eq $item -or -not (Test-ReparsePoint -Item $item)) {
    throw "Junction was not created: $SourcePath"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $SourcePath 'SKILL.md') -PathType Leaf)) {
    throw "SKILL.md is not readable through junction: $SourcePath"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $TargetPath 'SKILL.md') -PathType Leaf)) {
    throw "Target skill is missing SKILL.md: $TargetPath"
  }
}

$catalogData = Read-JsonFile -Path $CatalogNamesPath
if ($catalogData -is [array]) {
  $catalogNames = @($catalogData)
} elseif ($null -ne $catalogData -and ($catalogData.PSObject.Properties.Name -contains 'names')) {
  $catalogNames = @($catalogData.names)
} else {
  throw 'Catalog names JSON must be an array or an object with a names array.'
}
$catalogNames = @($catalogNames | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

$rowsData = Read-JsonFile -Path $RowsPath
$rows = @($rowsData)
if ($rows.Count -eq 1 -and $null -ne $rows[0] -and ($rows[0].PSObject.Properties.Name -contains 'rows')) {
  $rows = @($rows[0].rows)
}

$rowItems = @()
foreach ($row in $rows) {
  if ($null -eq $row) {
    continue
  }
  $propertyNames = @($row.PSObject.Properties.Name)
  if ($propertyNames -notcontains 'name' -or $propertyNames -notcontains 'description' -or $propertyNames -notcontains 'usageScenario') {
    throw 'Every new row must contain name, description, and usageScenario.'
  }
  $name = [string]$row.name
  $description = [string]$row.description
  $usageScenario = [string]$row.usageScenario
  if ([string]::IsNullOrWhiteSpace($name)) {
    throw 'Every new row must contain a non-empty name.'
  }
  if ([string]::IsNullOrWhiteSpace($description) -or [string]::IsNullOrWhiteSpace($usageScenario)) {
    throw "Row '$name' must contain description and usageScenario."
  }
  $rowItems += [pscustomobject]@{
    name = $name.Trim()
    description = $description.Trim()
    usageScenario = $usageScenario.Trim()
  }
}

$duplicateRows = @($rowItems | Group-Object name | Where-Object Count -gt 1)
if ($duplicateRows.Count -gt 0) {
  throw "Duplicate rows in input: $($duplicateRows.Name -join ', ')"
}

$plannedNames = @($rowItems | ForEach-Object { $_.name })
$relevantNames = @($catalogNames + $plannedNames | Sort-Object -Unique)
$candidates = [System.Collections.Generic.List[object]]::new()

foreach ($root in $SourceRoots) {
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Warning "Source root does not exist and will be skipped: $root"
    continue
  }

  foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -Force) {
    if ($directory.Name -in $excludedNames) {
      continue
    }
    if ($directory.Name -notin $relevantNames) {
      continue
    }
    if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName 'SKILL.md') -PathType Leaf)) {
      continue
    }
    $candidates.Add([pscustomobject]@{
      Name = $directory.Name
      SourceRoot = $root
      SourcePath = $directory.FullName
      TargetPath = Join-Path $TargetRoot $directory.Name
    })
  }
}

$duplicateCandidates = @($candidates | Group-Object Name | Where-Object Count -gt 1)
if ($duplicateCandidates.Count -gt 0) {
  throw "Duplicate skill names across source roots: $($duplicateCandidates.Name -join ', ')"
}

$actions = [System.Collections.Generic.List[object]]::new()
foreach ($name in $relevantNames) {
  $candidateMatches = @($candidates | Where-Object Name -eq $name)
  $sourcePath = if ($candidateMatches.Count -eq 1) { $candidateMatches[0].SourcePath } else { Join-Path $SourceRoots[0] $name }
  $targetPath = Join-Path $TargetRoot $name
  $sourceItem = Get-ItemIfExists -Path $sourcePath
  $targetExists = Test-Path -LiteralPath (Join-Path $targetPath 'SKILL.md') -PathType Leaf
  $isCataloged = $name -in $catalogNames
  $isNewRow = $name -in $plannedNames

  if ($isCataloged) {
    if ($candidateMatches.Count -gt 1) {
      throw "Duplicate skill names across source roots: $name"
    }
    if ($null -ne $sourceItem) {
      if (-not (Test-ReparsePoint -Item $sourceItem)) {
        throw "Cataloged skill is still a real directory and will not be moved again: $sourcePath"
      }
      if (-not $targetExists) {
        throw "Cataloged skill junction has no valid target: $sourcePath -> $targetPath"
      }
      $actions.Add([pscustomobject]@{
        name = $name
        action = 'already-complete'
        sourcePath = $sourcePath
        targetPath = $targetPath
        status = 'Verified'
      }) | Out-Null
      continue
    }
    if (-not $targetExists) {
      throw "Cataloged skill target is missing: $targetPath"
    }
    $actions.Add([pscustomobject]@{
      name = $name
      action = 'repair-junction'
      sourcePath = $sourcePath
      targetPath = $targetPath
      status = 'Planned'
    }) | Out-Null
    continue
  }

  if (-not $isNewRow) {
    continue
  }

  if ($candidateMatches.Count -eq 0) {
    if (-not $targetExists) {
      throw "New skill '$name' was not found in source roots or target library."
    }
    $actions.Add([pscustomobject]@{
      name = $name
      action = 'adopt-target'
      sourcePath = $sourcePath
      targetPath = $targetPath
      status = 'Planned'
    }) | Out-Null
    continue
  }

  if ($null -ne $sourceItem -and (Test-ReparsePoint -Item $sourceItem)) {
    if (-not $targetExists) {
      throw "Skill junction has no valid target: $sourcePath -> $targetPath"
    }
    $actions.Add([pscustomobject]@{
      name = $name
      action = 'already-complete'
      sourcePath = $sourcePath
      targetPath = $targetPath
      status = 'Verified'
    }) | Out-Null
    continue
  }

  if (Test-Path -LiteralPath $targetPath) {
    throw "Target conflict; refusing to overwrite: $targetPath"
  }

  Assert-SkillDirectory -Directory $sourcePath -Context 'Source skill'
  $actions.Add([pscustomobject]@{
    name = $name
    action = 'move'
    sourcePath = $sourcePath
    targetPath = $targetPath
    status = 'Planned'
  }) | Out-Null
}

$completedMoves = [System.Collections.Generic.List[object]]::new()
$createdJunctions = [System.Collections.Generic.List[string]]::new()

if ($Apply) {
  New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null

  try {
    foreach ($action in @($actions | Where-Object action -eq 'move')) {
      if (Test-Path -LiteralPath $action.targetPath) {
        throw "Target conflict; refusing to overwrite: $($action.targetPath)"
      }
      Move-Item -LiteralPath $action.sourcePath -Destination $action.targetPath
      Assert-SkillDirectory -Directory $action.targetPath -Context 'Moved target'
      New-Item -ItemType Junction -Path $action.sourcePath -Target $action.targetPath | Out-Null
      Assert-Junction -SourcePath $action.sourcePath -TargetPath $action.targetPath
      $completedMoves.Add($action) | Out-Null
      $createdJunctions.Add($action.sourcePath) | Out-Null
      $action.status = 'Applied'
    }

    foreach ($action in @($actions | Where-Object action -in @('repair-junction', 'adopt-target'))) {
      if ($null -ne (Get-ItemIfExists -Path $action.sourcePath)) {
        throw "Refusing to replace an existing source path: $($action.sourcePath)"
      }
      Assert-SkillDirectory -Directory $action.targetPath -Context 'Target skill'
      New-Item -ItemType Junction -Path $action.sourcePath -Target $action.targetPath | Out-Null
      Assert-Junction -SourcePath $action.sourcePath -TargetPath $action.targetPath
      $createdJunctions.Add($action.sourcePath) | Out-Null
      $action.status = 'Applied'
    }
  } catch {
    $failure = $_
    Write-Warning "Apply failed; rolling back this run. $($failure.Exception.Message)"

    for ($index = $createdJunctions.Count - 1; $index -ge 0; $index--) {
      $path = $createdJunctions[$index]
      try {
        $item = Get-ItemIfExists -Path $path
        if ($null -ne $item -and (Test-ReparsePoint -Item $item)) {
          Remove-Item -LiteralPath $path -Force
        }
      } catch {
        Write-Warning "Rollback could not remove junction: $path"
      }
    }

    for ($index = $completedMoves.Count - 1; $index -ge 0; $index--) {
      $action = $completedMoves[$index]
      try {
        $sourceItem = Get-ItemIfExists -Path $action.sourcePath
        if ($null -ne $sourceItem -and (Test-ReparsePoint -Item $sourceItem)) {
          Remove-Item -LiteralPath $action.sourcePath -Force
        }
        if (Test-Path -LiteralPath $action.targetPath) {
          Move-Item -LiteralPath $action.targetPath -Destination $action.sourcePath
        }
      } catch {
        Write-Warning "Rollback failed for $($action.name): $($_.Exception.Message)"
      }
    }

    throw $failure
  }
}

$report = [pscustomobject]@{
  applied = [bool]$Apply
  generatedAt = (Get-Date).ToString('o')
  targetRoot = $TargetRoot
  catalogNamesPath = $CatalogNamesPath
  rowsPath = $RowsPath
  counts = [pscustomobject]@{
    cataloged = $catalogNames.Count
    requested = $plannedNames.Count
    alreadyComplete = @($actions | Where-Object action -eq 'already-complete').Count
    toMove = @($actions | Where-Object action -eq 'move').Count
    toRepair = @($actions | Where-Object action -in @('repair-junction', 'adopt-target')).Count
  }
  actions = @($actions)
}

$reportDirectory = Split-Path -Parent $ReportPath
if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
  New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 6

