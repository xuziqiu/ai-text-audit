param(
  [Parameter(Mandatory = $true)]
  [string]$RunPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$SkillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$errors = [Collections.Generic.List[string]]::new()
$checks = [Collections.Generic.List[string]]::new()

function Add-Error([string]$Message) { $script:errors.Add($Message) }
function Add-Check([string]$Message) { $script:checks.Add($Message) }

function Invoke-JsonSchemaCheck([string]$InstancePath, [string]$SchemaPath, [string]$Label) {
  $validatorPath = Join-Path $SkillRoot "scripts\validate-json-schema.py"
  if (!(Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
    Add-Error "JSON Schema validator is missing: $validatorPath"
    return
  }
  if (!(Get-Command python -ErrorAction SilentlyContinue)) {
    Add-Error "Python is required to validate $Label against its JSON Schema."
    return
  }

  try {
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $schemaOutput = @(& python $validatorPath $InstancePath $SchemaPath 2>&1)
      $schemaExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorPreference
    }
    if ($schemaExitCode -ne 0) {
      $detail = ($schemaOutput | ForEach-Object { [string]$_ }) -join " | "
      Add-Error "$Label JSON Schema validation failed: $detail"
    } else {
      Add-Check "$Label conforms to its JSON Schema"
    }
  } catch {
    Add-Error "$Label JSON Schema validation could not run: $($_.Exception.Message)"
  }
}

function Get-FileSha256([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DirectorySha256([string]$Path) {
  $root = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
  $parts = foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName) {
    $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
    "$relative`n$(Get-FileSha256 $file.FullName)"
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-SafePath([string]$Root, [string]$Relative) {
  if ([string]::IsNullOrWhiteSpace($Relative)) { throw "Artifact path is empty." }
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  $candidate = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
  if (!$candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Artifact path escapes the run directory: $Relative" }
  $candidate
}

function Test-Substantive([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim().Length -ge 40
}

function Get-Band([double]$Score10) {
  if ($Score10 -ge 8.5) { return "excellent" }
  if ($Score10 -ge 7.0) { return "strong" }
  if ($Score10 -ge 5.5) { return "workable" }
  if ($Score10 -ge 4.0) { return "needs_substantial_revision" }
  return "failed"
}

function Get-BandRank([string]$Band) {
  switch ($Band) {
    "failed" { 0 }
    "needs_substantial_revision" { 1 }
    "workable" { 2 }
    "strong" { 3 }
    "excellent" { 4 }
    default { -1 }
  }
}

function Get-ConfidenceRank([string]$Confidence) {
  switch ($Confidence) {
    "low" { 1 }
    "medium" { 2 }
    "high" { 3 }
    default { 0 }
  }
}

function Write-Validation([string]$Path, [bool]$Passed) {
  $status = if ($Passed) { "passed" } else { "failed" }
  $lines = @(
    "# XZQ Text Audit Run Validation", "", "- Result: $status",
    "- Time: $((Get-Date).ToUniversalTime().ToString('o'))", "", "## Checks", ""
  )
  $lines += if ($checks.Count -gt 0) { $checks | ForEach-Object { "- $_" } } else { "- none" }
  $lines += @("", "## Errors", "")
  $lines += if ($errors.Count -gt 0) { $errors | ForEach-Object { "- $_" } } else { "- none" }
  [IO.File]::WriteAllText($Path, ($lines -join [Environment]::NewLine) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

$root = [IO.Path]::GetFullPath($RunPath)
if (!(Test-Path -LiteralPath $root -PathType Container)) { throw "Run directory not found: $root" }
$manifestPath = Join-Path $root "run.json"
if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Run manifest not found: $manifestPath" }

try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { throw "Run manifest is not valid JSON: $($_.Exception.Message)" }

Invoke-JsonSchemaCheck $manifestPath (Join-Path $SkillRoot "assets\run-manifest.schema.json") "run.json"

foreach ($property in @("schema_version", "run_id", "artifact_profile", "status", "scope", "source", "skill", "scoring", "stages", "artifacts", "artifact_hashes", "history")) {
  if ($manifest.PSObject.Properties.Name -notcontains $property) { Add-Error "run.json lacks property: $property" }
}
if ($manifest.schema_version -ne 1) { Add-Error "schema_version must be 1." }
if ($manifest.artifact_profile -notin @("compact", "full_trace")) { Add-Error "artifact_profile is invalid." }
if ($manifest.scoring.version -ne "xzq-text-audit-score-v1") { Add-Error "scoring contract must be xzq-text-audit-score-v1." }
if ($manifest.scoring.scale -ne "0-10") { Add-Error "scoring scale must be 0-10." }

foreach ($stage in @("intake", "first_read", "reconstruction", "open_scan", "focused_review", "fact_check", "synthesis", "report", "validation")) {
  if ($manifest.stages.PSObject.Properties.Name -notcontains $stage) { Add-Error "Missing stage: $stage" }
}

try {
  $sourcePath = Get-SafePath $root ([string]$manifest.source.path)
  if ((Get-FileSha256 $sourcePath) -ne [string]$manifest.source.sha256) { Add-Error "Frozen source hash mismatch." } else { Add-Check "Frozen source identity matches" }
} catch { Add-Error $_.Exception.Message }

if ((Get-DirectorySha256 $SkillRoot) -ne [string]$manifest.skill.sha256) { Add-Error "XZQ text audit skill hash mismatch." } else { Add-Check "Skill identity matches" }

foreach ($property in $manifest.artifact_hashes.PSObject.Properties) {
  try {
    $path = Get-SafePath $root $property.Name
    $actual = Get-FileSha256 $path
    if ($null -eq $actual) { Add-Error "Frozen artifact is missing: $($property.Name)" }
    elseif ($actual -ne [string]$property.Value) { Add-Error "Frozen artifact changed: $($property.Name)" }
    else { Add-Check "Frozen artifact unchanged: $($property.Name)" }
  } catch { Add-Error $_.Exception.Message }
}

$reportStageFiles = @([string]$manifest.artifacts.scorecard, [string]$manifest.artifacts.report)
if ($manifest.artifact_profile -eq "full_trace") {
  $reportStageFiles += @("working/05-report-coverage-draft.md", "working/06-report-editorial-review.md")
}
$stageFiles = [ordered]@{
  first_read = @([string]$manifest.artifacts.initial_core_judgment)
  reconstruction = if ($manifest.artifact_profile -eq "full_trace") { @("working/01-writing-structure.md", "working/02-content-function-map.md") } else { @() }
  open_scan = if ($manifest.artifact_profile -eq "full_trace") { @("working/03-open-scan.md") } else { @() }
  focused_review = if ($manifest.artifact_profile -eq "full_trace") { @("working/04-focused-review.md") } else { @() }
  synthesis = @([string]$manifest.artifacts.synthesis)
  report = $reportStageFiles
}

foreach ($entry in $stageFiles.GetEnumerator()) {
  if ($manifest.stages.($entry.Key) -eq "completed") {
    foreach ($relative in @($entry.Value)) {
      try {
        $path = Get-SafePath $root $relative
        if (!(Test-Substantive $path)) { Add-Error "Completed stage lacks substantive artifact: $($entry.Key) -> $relative" }
      } catch { Add-Error $_.Exception.Message }
    }
  }
}

if ($manifest.artifact_profile -eq "full_trace" -and $manifest.stages.open_scan -eq "completed") {
  try {
    $scanPath = Get-SafePath $root "working/03-open-scan.md"
    $scanText = Get-Content -LiteralPath $scanPath -Raw -Encoding UTF8
    $observationIds = @([regex]::Matches($scanText, '(?im)\bOBS-(\d{3,})\b') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)
    if ($observationIds.Count -lt 50) { Add-Error "full_trace open scan must contain at least 50 unique OBS identifiers." }
    else { Add-Check "Open scan contains at least 50 unique observations" }
  } catch { Add-Error $_.Exception.Message }
}

if ($manifest.stages.fact_check -in @("completed", "partial")) {
  try {
    $sourcesPath = Get-SafePath $root ([string]$manifest.artifacts.sources)
    if (!(Test-Substantive $sourcesPath)) { Add-Error "fact_check is resolved but sources.md is not substantive." }
  } catch { Add-Error $_.Exception.Message }
}

if ($manifest.stages.synthesis -eq "completed") {
  $synthesisPath = Get-SafePath $root ([string]$manifest.artifacts.synthesis)
  if (!(Test-Substantive $synthesisPath)) { Add-Error "synthesis.md is not substantive." }
}

if ($manifest.stages.report -eq "completed") {
  $reportPath = Get-SafePath $root ([string]$manifest.artifacts.report)
  if (!(Test-Substantive $reportPath)) { Add-Error "report.md is not substantive." }
  else {
    $reportText = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
    $auditNote = -join @([char]0x5BA1, [char]0x8BA1, [char]0x8BF4, [char]0x660E)
    $snapshotHeading = "## 1. " + (-join @([char]0x7ED3, [char]0x8BBA, [char]0x901F, [char]0x89C8))
    $conclusionHeading = "## 2. " + (-join @([char]0x603B, [char]0x4F53, [char]0x7ED3, [char]0x8BBA))
    $dimensionHeading = "## 3. " + (-join @([char]0x516D, [char]0x7EF4, [char]0x8BC4, [char]0x4F30))
    $skeletonHeading = "## 4. " + (-join @([char]0x6587, [char]0x7AE0, [char]0x884C, [char]0x6587, [char]0x9AA8, [char]0x67B6))
    $fullAuditHeading = "## " + (-join @([char]0x5168, [char]0x6587, [char]0x5BA1, [char]0x8BA1))
    $auditIndex = $reportText.IndexOf($auditNote)
    $snapshotIndex = $reportText.IndexOf($snapshotHeading)
    $conclusionIndex = $reportText.IndexOf($conclusionHeading)
    $dimensionIndex = $reportText.IndexOf($dimensionHeading)
    $skeletonIndex = $reportText.IndexOf($skeletonHeading)
    if ($auditIndex -lt 0) { Add-Error "report.md lacks a reader-facing audit note." }
    if ($snapshotIndex -lt 0) { Add-Error "report.md lacks the conclusion snapshot." }
    if ($conclusionIndex -lt 0) { Add-Error "report.md lacks the overall conclusion." }
    if ($dimensionIndex -lt 0) { Add-Error "report.md lacks the six-dimensional evaluation." }
    if ($skeletonIndex -lt 0) { Add-Error "report.md lacks the writing skeleton." }
    if ($auditIndex -ge 0 -and $snapshotIndex -ge 0 -and $auditIndex -gt $snapshotIndex) { Add-Error "Audit note must appear before the conclusion snapshot." }
    if ($snapshotIndex -ge 0 -and $conclusionIndex -ge 0 -and $snapshotIndex -gt $conclusionIndex) { Add-Error "Conclusion snapshot must appear before the overall conclusion." }
    if ($conclusionIndex -ge 0 -and $dimensionIndex -ge 0 -and $conclusionIndex -gt $dimensionIndex) { Add-Error "Overall conclusion must appear before the six-dimensional evaluation." }
    if ($dimensionIndex -ge 0 -and $skeletonIndex -ge 0 -and $dimensionIndex -gt $skeletonIndex) { Add-Error "Six-dimensional evaluation must appear before the writing skeleton." }
    if ($reportText.Contains($fullAuditHeading)) { Add-Error "report.md must not restore a fixed full-audit section." }
    foreach ($internalToken in @("fact_check_status", "load_bearing", "detail_refs", "G1", "G2", "G3", "G4", "P0", "P1", "P2")) {
      if ($reportText -match "(?<![A-Za-z0-9_])$internalToken(?![A-Za-z0-9_])") { Add-Error "report.md exposes internal token: $internalToken" }
    }
    $sourcesHeading = "## 10. " + (-join @([char]0x6765, [char]0x6E90))
    $sourcesIndex = $reportText.IndexOf($sourcesHeading)
    $bodyBeforeSources = if ($sourcesIndex -ge 0) { $reportText.Substring(0, $sourcesIndex) } else { $reportText }
    if ($bodyBeforeSources -match 'https?://') { Add-Error "External URLs must be collected in the final sources section." }
  }
  if ($manifest.artifact_profile -eq "full_trace") {
    $editorialPath = Get-SafePath $root "working/06-report-editorial-review.md"
    if (Test-Substantive $editorialPath) {
      $editorialText = Get-Content -LiteralPath $editorialPath -Raw -Encoding UTF8
      if ($editorialText -notmatch '(?im)^- Result:\s*passed\s*$') { Add-Error "Editorial review must record Result: passed." }
    }
  }
}

if ($manifest.stages.report -eq "completed") {
  $scorecardPath = Get-SafePath $root ([string]$manifest.artifacts.scorecard)
  if (!(Test-Substantive $scorecardPath)) {
    Add-Error "scorecard.json is not substantive."
  } else {
    try {
      $scorecard = Get-Content -LiteralPath $scorecardPath -Raw -Encoding UTF8 | ConvertFrom-Json
      Invoke-JsonSchemaCheck $scorecardPath (Join-Path $SkillRoot "assets\scorecard.schema.json") "scorecard.json"
      if ($scorecard.schema_version -ne 1) { Add-Error "scorecard schema_version must be 1." }
      if ($scorecard.scoring_version -ne "xzq-text-audit-score-v1") { Add-Error "scorecard scoring_version is invalid." }

      $dimensionNames = @(
        "task_fulfillment", "evidence_grounding", "reasoning_explanation",
        "structure_organization", "language_expression", "perspective_boundary"
      )
      $expectedWeights = @{
        task_fulfillment = 25; evidence_grounding = 20; reasoning_explanation = 20;
        structure_organization = 12; language_expression = 10; perspective_boundary = 13
      }
      $weightSum = 0.0
      $weightedSum = 0.0
      $loadBearingConfidences = @()

      foreach ($name in $dimensionNames) {
        $dimension = $scorecard.dimensions.$name
        if ($null -eq $dimension) { Add-Error "scorecard lacks dimension: $name"; continue }
        if ([double]$dimension.weight -ne [double]$expectedWeights[$name]) { Add-Error "scorecard weight is invalid: $name" }
        if ([bool]$dimension.applicable) {
          if ($null -eq $dimension.score) { Add-Error "applicable dimension has null score: $name"; continue }
          $score = [double]$dimension.score
          if ($score -lt 0 -or $score -gt 10 -or ([math]::Abs(($score * 2) - [math]::Round($score * 2)) -gt 0.0001)) {
            Add-Error "dimension score must use 0.5 increments from 0 to 10: $name"
          }
          if ($dimension.confidence -notin @("high", "medium", "low")) { Add-Error "applicable dimension confidence is invalid: $name" }
          $weightSum += [double]$dimension.weight
          $weightedSum += [double]$dimension.weight * $score
          if ([bool]$dimension.load_bearing) { $loadBearingConfidences += [string]$dimension.confidence }
        } else {
          if ($null -ne $dimension.score) { Add-Error "non-applicable dimension must have null score: $name" }
          if ($dimension.confidence -ne "not_applicable") { Add-Error "non-applicable dimension confidence must be not_applicable: $name" }
          if ([bool]$dimension.load_bearing) { Add-Error "non-applicable dimension cannot be load-bearing: $name" }
        }
        if ([string]::IsNullOrWhiteSpace([string]$dimension.verdict)) { Add-Error "dimension verdict is empty: $name" }
        if ([bool]$dimension.applicable -and (@($dimension.strengths).Count + @($dimension.limitations).Count -lt 1)) { Add-Error "applicable dimension needs a strength or limitation: $name" }
        if (@($dimension.detail_refs).Count -lt 1) { Add-Error "dimension detail_refs is empty: $name" }
      }

      if ($weightSum -le 0) {
        Add-Error "scorecard has no applicable dimensions."
      } else {
        $expected10 = [math]::Round($weightedSum / $weightSum, 1, [MidpointRounding]::AwayFromZero)
        if ([math]::Abs(([double]$scorecard.composite.score_10 - $expected10)) -gt 0.05) { Add-Error "scorecard score_10 does not match dimension calculation." }
        $expectedBand = Get-Band $expected10
        if ($scorecard.composite.calculated_quality_band -ne $expectedBand) { Add-Error "scorecard calculated_quality_band does not match score_10." }
      }

      $gateMap = @{}
      foreach ($gate in @($scorecard.gates)) {
        if ($gate.id -notin @("G1", "G2", "G3", "G4")) { Add-Error "scorecard contains invalid gate id: $($gate.id)"; continue }
        if ($gateMap.ContainsKey([string]$gate.id)) { Add-Error "scorecard repeats gate: $($gate.id)" }
        $gateMap[[string]$gate.id] = [bool]$gate.triggered
      }
      foreach ($gateId in @("G1", "G2", "G3", "G4")) {
        if (!$gateMap.ContainsKey($gateId)) { Add-Error "scorecard lacks gate: $gateId" }
      }

      $task = $scorecard.dimensions.task_fulfillment
      $evidence = $scorecard.dimensions.evidence_grounding
      $reasoning = $scorecard.dimensions.reasoning_explanation
      $boundary = $scorecard.dimensions.perspective_boundary
      $expectG1 = [bool]$task.applicable -and [double]$task.score -lt 6
      $expectG2 = ([bool]$evidence.applicable -and [bool]$evidence.load_bearing -and [double]$evidence.score -lt 6) -or
                  ([bool]$reasoning.applicable -and [bool]$reasoning.load_bearing -and [double]$reasoning.score -lt 6)
      $expectG3 = [bool]$scorecard.verdict.provisional
      $expectG4 = [bool]$boundary.applicable -and [bool]$boundary.load_bearing -and [double]$boundary.score -lt 4
      if ($gateMap.ContainsKey("G1") -and $gateMap["G1"] -ne $expectG1) { Add-Error "G1 trigger does not match task score." }
      if ($gateMap.ContainsKey("G2") -and $gateMap["G2"] -ne $expectG2) { Add-Error "G2 trigger does not match load-bearing reliability scores." }
      if ($gateMap.ContainsKey("G3") -and $gateMap["G3"] -ne $expectG3) { Add-Error "G3 trigger must match provisional verdict." }
      if ($gateMap.ContainsKey("G4") -and $gateMap["G4"] -ne $expectG4) { Add-Error "G4 trigger does not match load-bearing boundary score." }

      $calculatedRank = Get-BandRank ([string]$scorecard.composite.calculated_quality_band)
      $finalRank = Get-BandRank ([string]$scorecard.composite.final_quality_band)
      if ($finalRank -lt 0 -or $finalRank -gt $calculatedRank) { Add-Error "final_quality_band cannot exceed calculated_quality_band." }
      if ($expectG1 -and $finalRank -gt (Get-BandRank "needs_substantial_revision")) { Add-Error "G1 quality cap is not applied." }
      if ($expectG2) {
        $criticalReliability = ([bool]$evidence.applicable -and [bool]$evidence.load_bearing -and [double]$evidence.score -lt 4) -or
                               ([bool]$reasoning.applicable -and [bool]$reasoning.load_bearing -and [double]$reasoning.score -lt 4)
        $cap = if ($criticalReliability) { Get-BandRank "failed" } else { Get-BandRank "workable" }
        if ($finalRank -gt $cap) { Add-Error "G2 reliability cap is not applied." }
      }
      if ($expectG4 -and $finalRank -gt (Get-BandRank "needs_substantial_revision")) { Add-Error "G4 quality cap is not applied." }

      if ($scorecard.core_task.status -notin @("established", "mostly_established", "partially_established", "not_established", "not_applicable")) { Add-Error "core_task status is invalid." }
      if ([bool]$task.applicable -and [double]$task.score -lt 6 -and $scorecard.core_task.status -eq "established") { Add-Error "core_task cannot be established when task score is below 6." }
      foreach ($field in @("display_name", "label", "explanation")) {
        if ([string]::IsNullOrWhiteSpace([string]$scorecard.core_task.$field)) { Add-Error "core_task field is empty: $field" }
      }

      if ($loadBearingConfidences.Count -lt 1) {
        Add-Error "scorecard has no load-bearing applicable dimension."
      } else {
        $minimumConfidence = $loadBearingConfidences | Sort-Object { Get-ConfidenceRank $_ } | Select-Object -First 1
        if ($scorecard.verdict.confidence -ne $minimumConfidence) { Add-Error "overall confidence must equal the lowest load-bearing confidence." }
      }

      $reportPath = Get-SafePath $root ([string]$manifest.artifacts.report)
      $reportText = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
      $previousSectionIndex = -1
      foreach ($sectionNumber in 1..10) {
        $sectionMarker = "## $sectionNumber."
        $sectionIndex = $reportText.IndexOf($sectionMarker, [StringComparison]::Ordinal)
        if ($sectionIndex -lt 0) { Add-Error "report.md lacks fixed public section number: $sectionNumber" }
        elseif ($sectionIndex -le $previousSectionIndex) { Add-Error "report.md fixed public sections are out of order at: $sectionNumber" }
        else { $previousSectionIndex = $sectionIndex }
      }
      foreach ($treeCharacter in @([char]0x2502, [char]0x251C, [char]0x2514)) {
        if (!$reportText.Contains([string]$treeCharacter)) { Add-Error "report.md lacks the Unicode writing-skeleton tree." }
      }
      if ($reportText.Contains("Mermaid") -or $reportText.Contains('```mermaid')) { Add-Error "report.md must not use Mermaid for the writing skeleton." }
      if ($manifest.stages.fact_check -ne "not_applicable") {
        foreach ($factLabel in @(
          (-join @([char]0x4E8B, [char]0x5B9E, [char]0x58F0, [char]0x660E)),
          (-join @([char]0x6838, [char]0x67E5, [char]0x7ED3, [char]0x8BBA)),
          (-join @([char]0x8BF4, [char]0x660E))
        )) {
          if (!$reportText.Contains($factLabel)) { Add-Error "report.md key fact-check table lacks a required public column." }
        }
      }
      if (!$reportText.Contains(([string]$scorecard.composite.score_10))) { Add-Error "report.md does not contain scorecard score_10." }
      if (!$reportText.Contains([string]$scorecard.composite.quality_label)) { Add-Error "report.md does not contain the quality label." }
      if (!$reportText.Contains([string]$scorecard.core_task.label)) { Add-Error "report.md does not contain the core task label." }
      if (!$reportText.Contains([string]$scorecard.core_task.explanation)) { Add-Error "report.md does not contain the core task explanation." }
      foreach ($name in $dimensionNames) {
        $dimension = $scorecard.dimensions.$name
        if ([bool]$dimension.applicable -and !$reportText.Contains(([string]$dimension.score))) { Add-Error "report.md lacks dimension score: $name" }
        if (!$reportText.Contains([string]$dimension.verdict)) { Add-Error "report.md lacks dimension verdict: $name" }
      }
      if ($errors.Count -eq 0) { Add-Check "Scorecard quality, core task, gates, confidence, and report projection match" }
    } catch {
      Add-Error "scorecard.json is not valid: $($_.Exception.Message)"
    }
  }
}

$completionOrder = @("first_read", "reconstruction", "open_scan", "focused_review", "synthesis", "report")
$lastIndex = -1
foreach ($stage in $completionOrder) {
  $index = -1
  for ($i = 0; $i -lt @($manifest.history).Count; $i++) {
    $item = @($manifest.history)[$i]
    if ($item.event -eq "stage_changed" -and $item.stage -eq $stage -and $item.to -eq "completed") { $index = $i; break }
  }
  if ($manifest.stages.$stage -eq "completed") {
    if ($index -lt 0) { Add-Error "Completed stage has no history entry: $stage" }
    elseif ($index -le $lastIndex) { Add-Error "Stage completion order is invalid at: $stage" }
    else { $lastIndex = $index }
  }
}

if ($manifest.stages.report -ne "completed") { Add-Error "report must be completed before validation." }
if ($manifest.stages.synthesis -ne "completed") { Add-Error "synthesis must be completed before validation." }
if ($manifest.stages.fact_check -notin @("completed", "partial", "not_applicable")) { Add-Error "fact_check must be resolved before validation." }

$validationPath = Get-SafePath $root ([string]$manifest.artifacts.validation)
if ($errors.Count -gt 0) {
  if ($manifest.stages.validation -ne "completed") { Write-Validation $validationPath $false }
  foreach ($errorText in $errors) { Write-Error $errorText }
  throw "XZQ text audit run validation failed with $($errors.Count) error(s)."
}

if ($manifest.stages.validation -ne "completed") {
  Write-Validation $validationPath $true
} else {
  Add-Check "Completed validation artifact was verified without rewriting it"
}

Write-Output "XZQ text audit run validation passed"
