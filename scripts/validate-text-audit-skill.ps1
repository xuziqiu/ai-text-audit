param(
  [string]$SkillPath = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$SkillRoot = if ([string]::IsNullOrWhiteSpace($SkillPath)) { Split-Path -Parent (Split-Path -Parent $PSCommandPath) } else { [IO.Path]::GetFullPath($SkillPath) }
$errors = [Collections.Generic.List[string]]::new()

function Add-ValidationError([string]$Message) { $script:errors.Add($Message) }
function Read-Utf8([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
  Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

$required = @(
  "SKILL.md",
  "agents\openai.yaml",
  "references\initial-core-judgment.md",
  "references\reconstruction.md",
  "references\open-scan.md",
  "references\focused-review.md",
  "references\fact-check.md",
  "references\synthesis.md",
  "references\scoring.md",
  "references\report.md",
  "references\runtime-protocol.md",
  "references\regression-suite.md",
  "assets\run-manifest.schema.json",
  "assets\scorecard.schema.json",
  "scripts\manage-audit-run.ps1",
  "scripts\validate-audit-run.ps1",
  "scripts\validate-json-schema.py"
)
foreach ($relative in $required) {
  if (!(Test-Path -LiteralPath (Join-Path $SkillRoot $relative) -PathType Leaf)) { Add-ValidationError "Missing required file: $relative" }
}

$skill = Read-Utf8 (Join-Path $SkillRoot "SKILL.md")
$initial = Read-Utf8 (Join-Path $SkillRoot "references\initial-core-judgment.md")
$reconstruction = Read-Utf8 (Join-Path $SkillRoot "references\reconstruction.md")
$scan = Read-Utf8 (Join-Path $SkillRoot "references\open-scan.md")
$focused = Read-Utf8 (Join-Path $SkillRoot "references\focused-review.md")
$fact = Read-Utf8 (Join-Path $SkillRoot "references\fact-check.md")
$synthesis = Read-Utf8 (Join-Path $SkillRoot "references\synthesis.md")
$scoring = Read-Utf8 (Join-Path $SkillRoot "references\scoring.md")
$report = Read-Utf8 (Join-Path $SkillRoot "references\report.md")
$runtime = Read-Utf8 (Join-Path $SkillRoot "references\runtime-protocol.md")
$regression = Read-Utf8 (Join-Path $SkillRoot "references\regression-suite.md")
$manage = Read-Utf8 (Join-Path $SkillRoot "scripts\manage-audit-run.ps1")
$validateRun = Read-Utf8 (Join-Path $SkillRoot "scripts\validate-audit-run.ps1")
$validateSchema = Read-Utf8 (Join-Path $SkillRoot "scripts\validate-json-schema.py")
$agent = Read-Utf8 (Join-Path $SkillRoot "agents\openai.yaml")

if ($skill -notmatch '(?s)^---\s*\r?\nname:\s*xzq-text-audit\s*\r?\ndescription:.+?\r?\n---') { Add-ValidationError "SKILL.md frontmatter name or description is invalid." }
if ($skill -notmatch '(?m)^# XZQ Text Audit\s*$') { Add-ValidationError "SKILL.md title does not identify XZQ Text Audit." }

foreach ($link in @(
  "references/initial-core-judgment.md",
  "references/reconstruction.md",
  "references/open-scan.md",
  "references/focused-review.md",
  "references/fact-check.md",
  "references/synthesis.md",
  "references/scoring.md",
  "references/report.md",
  "references/runtime-protocol.md",
  "references/regression-suite.md"
)) {
  if (!$skill.Contains($link)) { Add-ValidationError "SKILL.md does not route to: $link" }
}

foreach ($traceName in @(
  "00-initial-core-judgment.md",
  "01-writing-structure.md",
  "02-content-function-map.md",
  "03-open-scan.md",
  "04-focused-review.md",
  "05-report-coverage-draft.md",
  "06-report-editorial-review.md"
)) {
  if (!$skill.Contains($traceName)) { Add-ValidationError "SKILL.md lacks full_trace artifact: $traceName" }
  if (!$runtime.Contains($traceName)) { Add-ValidationError "runtime-protocol.md lacks full_trace artifact: $traceName" }
}

foreach ($legacy in @("claim-extraction.md", "core-insight.md", "full-scan.md", "argument-mechanism.md", "value-calibration.md")) {
  if ($skill.Contains($legacy)) { Add-ValidationError "SKILL.md still links legacy module: $legacy" }
  if (Test-Path -LiteralPath (Join-Path $SkillRoot "references\$legacy")) { Add-ValidationError "Legacy module exists in the stable Skill: $legacy" }
}

foreach ($document in @(
  @{ Name = "initial-core-judgment.md"; Text = $initial; Min = 300 },
  @{ Name = "reconstruction.md"; Text = $reconstruction; Min = 500 },
  @{ Name = "open-scan.md"; Text = $scan; Min = 700 },
  @{ Name = "focused-review.md"; Text = $focused; Min = 700 },
  @{ Name = "fact-check.md"; Text = $fact; Min = 500 },
  @{ Name = "synthesis.md"; Text = $synthesis; Min = 900 },
  @{ Name = "scoring.md"; Text = $scoring; Min = 1800 },
  @{ Name = "report.md"; Text = $report; Min = 1200 },
  @{ Name = "runtime-protocol.md"; Text = $runtime; Min = 900 },
  @{ Name = "regression-suite.md"; Text = $regression; Min = 700 }
)) {
  if ($document.Text.Trim().Length -lt $document.Min) { Add-ValidationError "$($document.Name) is too short to carry its responsibility." }
}

if ($agent -notmatch '(?m)^\s*display_name:\s*"XZQ ') {
  Add-ValidationError "agents/openai.yaml display_name does not start with XZQ."
}
if ($agent -notmatch '(?m)^\s*allow_implicit_invocation:\s*false\s*$') { Add-ValidationError "agents/openai.yaml must disable implicit invocation." }
if ($agent -notmatch '\$xzq-text-audit') { Add-ValidationError "agents/openai.yaml default prompt does not name xzq-text-audit." }

try {
  $schema = Read-Utf8 (Join-Path $SkillRoot "assets\run-manifest.schema.json") | ConvertFrom-Json
  if ($schema.title -ne "XZQ Text Audit Run Manifest") { Add-ValidationError "Manifest schema title is invalid." }
  foreach ($stage in @("first_read", "reconstruction", "open_scan", "focused_review")) {
    if ($schema.properties.stages.properties.PSObject.Properties.Name -notcontains $stage) { Add-ValidationError "Manifest schema lacks stage: $stage" }
  }
  if ($null -eq $schema.properties.artifact_hashes) { Add-ValidationError "Manifest schema lacks artifact_hashes." }
  if ($null -eq $schema.properties.artifacts.properties.initial_core_judgment) { Add-ValidationError "Manifest schema lacks initial_core_judgment artifact." }
  if ($null -eq $schema.properties.artifacts.properties.scorecard) { Add-ValidationError "Manifest schema lacks scorecard artifact." }
  if ($schema.properties.scoring.properties.version.const -ne "xzq-text-audit-score-v1") { Add-ValidationError "Manifest schema scoring contract is invalid." }
  if ($schema.properties.scoring.properties.scale.const -ne "0-10") { Add-ValidationError "Manifest schema scoring scale is invalid." }
} catch { Add-ValidationError "Manifest schema is not valid JSON: $($_.Exception.Message)" }

try {
  $scoreSchema = Read-Utf8 (Join-Path $SkillRoot "assets\scorecard.schema.json") | ConvertFrom-Json
  if ($scoreSchema.title -ne "XZQ Text Audit Scorecard") { Add-ValidationError "Scorecard schema title is invalid." }
  foreach ($dimension in @("task_fulfillment", "evidence_grounding", "reasoning_explanation", "structure_organization", "language_expression", "perspective_boundary")) {
    if ($scoreSchema.properties.dimensions.properties.PSObject.Properties.Name -notcontains $dimension) { Add-ValidationError "Scorecard schema lacks dimension: $dimension" }
  }
  if ($scoreSchema.properties.scoring_version.const -ne "xzq-text-audit-score-v1") { Add-ValidationError "Scorecard schema version is invalid." }
  if ($null -eq $scoreSchema.properties.composite.properties.score_10) { Add-ValidationError "Scorecard schema lacks score_10." }
  foreach ($field in @("calculated_quality_band", "final_quality_band", "quality_label")) {
    if ($scoreSchema.properties.composite.properties.PSObject.Properties.Name -notcontains $field) { Add-ValidationError "Scorecard composite lacks field: $field" }
  }
  if ($null -eq $scoreSchema.properties.core_task) { Add-ValidationError "Scorecard schema lacks core_task." }
  foreach ($field in @("kind", "display_name", "status", "label", "explanation")) {
    if ($scoreSchema.properties.core_task.properties.PSObject.Properties.Name -notcontains $field) { Add-ValidationError "Scorecard core_task lacks field: $field" }
  }
  if ($scoreSchema.properties.verdict.properties.PSObject.Properties.Name -contains "final_band") { Add-ValidationError "Scorecard verdict must not conflate quality with task establishment." }
  foreach ($field in @("verdict", "strengths", "limitations", "detail_refs")) {
    if ($scoreSchema.'$defs'.dimension.properties.PSObject.Properties.Name -notcontains $field) { Add-ValidationError "Scorecard dimension lacks field: $field" }
  }
} catch { Add-ValidationError "Scorecard schema is not valid JSON: $($_.Exception.Message)" }

foreach ($scriptRule in @(
  @{ Text = $manage; Phrase = 'ValidateSet("Init", "Status", "SetStage", "SetStatus", "AddLimitation", "VerifyResume")'; File = "manage-audit-run.ps1" },
  @{ Text = $manage; Phrase = "Source hash mismatch"; File = "manage-audit-run.ps1" },
  @{ Text = $manage; Phrase = "Skill hash mismatch"; File = "manage-audit-run.ps1" },
  @{ Text = $manage; Phrase = "Frozen artifact hash mismatch"; File = "manage-audit-run.ps1" },
  @{ Text = $manage; Phrase = "Cannot complete open_scan before it contains at least 50 unique OBS identifiers"; File = "manage-audit-run.ps1" },
  @{ Text = $manage; Phrase = "Cannot complete reconstruction before first_read is completed"; File = "manage-audit-run.ps1" },
  @{ Text = $manage; Phrase = '& $validatorPath -RunPath $runFullPath'; File = "manage-audit-run.ps1" },
  @{ Text = $manage; Phrase = 'scorecard = "scorecard.json"'; File = "manage-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "Artifact path escapes the run directory"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "Frozen artifact changed"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "scorecard score_10 does not match dimension calculation"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "Editorial review must record Result: passed"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "full_trace open scan must contain at least 50 unique OBS identifiers"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "Scorecard quality, core task, gates, confidence, and report projection match"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "Invoke-JsonSchemaCheck"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "report.md lacks fixed public section number"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = "report.md lacks the Unicode writing-skeleton tree"; File = "validate-audit-run.ps1" },
  @{ Text = $validateRun; Phrase = 'if ($manifest.stages.validation -ne "completed")'; File = "validate-audit-run.ps1" }
)) {
  if (!$scriptRule.Text.Contains($scriptRule.Phrase)) { Add-ValidationError "$($scriptRule.File) missing guard: $($scriptRule.Phrase)" }
}

foreach ($schemaScriptPhrase in @("Draft202012Validator.check_schema", "FormatChecker", "utf-8")) {
  if (!$validateSchema.Contains($schemaScriptPhrase)) { Add-ValidationError "validate-json-schema.py missing guard: $schemaScriptPhrase" }
}

foreach ($reportRule in @(
  "working/05-report-coverage-draft.md",
  "working/06-report-editorial-review.md",
  "R0",
  "R1"
)) {
  if (!$report.Contains($reportRule)) { Add-ValidationError "report.md lacks report compiler rule: $reportRule" }
}
if (!$scoring.Contains("score_10")) { Add-ValidationError "scoring.md lacks score_10 output rule." }
if (!$scan.Contains("50") -or !$scan.Contains("OBS-001")) { Add-ValidationError "open-scan.md lacks the 50-observation floor and stable ID rule." }
if (!$focused.Contains("50")) { Add-ValidationError "focused-review.md lacks the weak selection rule." }
foreach ($sectionNumber in 1..10) {
  if (!$report.Contains("## $sectionNumber.")) { Add-ValidationError "report.md lacks fixed public section number: $sectionNumber" }
}
foreach ($treeCharacter in @([char]0x2502, [char]0x251C, [char]0x2514)) {
  if (!$report.Contains([string]$treeCharacter)) { Add-ValidationError "report.md lacks the Unicode directory-tree convention." }
}
if ($report.Contains("Mermaid")) { Add-ValidationError "report.md must use the Unicode directory tree instead of Mermaid." }

$requiredPublicLabels = @(
  (-join @([char]0x7ED3, [char]0x8BBA, [char]0x901F, [char]0x89C8)),
  (-join @([char]0x5176, [char]0x4ED6, [char]0x5173, [char]0x952E, [char]0x53D1, [char]0x73B0)),
  (-join @([char]0x4EFB, [char]0x52A1, [char]0x4E0E, [char]0x6210, [char]0x6548)),
  (-join @([char]0x4E8B, [char]0x5B9E, [char]0x4E0E, [char]0x6750, [char]0x6599)),
  (-join @([char]0x63A8, [char]0x7406, [char]0x4E0E, [char]0x5224, [char]0x65AD)),
  (-join @([char]0x7ED3, [char]0x6784, [char]0x4E0E, [char]0x63A8, [char]0x8FDB)),
  (-join @([char]0x4FEE, [char]0x6539, [char]0x65F6, [char]0x5E94, [char]0x5F53, [char]0x4FDD, [char]0x7559)),
  (-join @([char]0x5FC5, [char]0x987B, [char]0x4FEE, [char]0x6539)),
  (-join @([char]0x672C, [char]0x62A5, [char]0x544A, [char]0x7ED3, [char]0x8BBA, [char]0x7684, [char]0x628A, [char]0x63E1, [char]0x5EA6)),
  (-join @([char]0x5206, [char]0x6790, [char]0x6536, [char]0x675F)),
  (-join @([char]0x5173, [char]0x952E, [char]0x4E8B, [char]0x5B9E, [char]0x6838, [char]0x67E5)),
  (-join @([char]0x4E8B, [char]0x5B9E, [char]0x58F0, [char]0x660E)),
  (-join @([char]0x6838, [char]0x67E5, [char]0x7ED3, [char]0x8BBA))
)
foreach ($label in $requiredPublicLabels) {
  if (!$report.Contains($label) -and !$skill.Contains($label)) { Add-ValidationError "XZQ text audit public report label is missing." }
}

$markdownFiles = Get-ChildItem -LiteralPath $SkillRoot -Recurse -File -Filter "*.md"
foreach ($markdownFile in $markdownFiles) {
  $markdownText = Read-Utf8 $markdownFile.FullName
  foreach ($match in [regex]::Matches($markdownText, '\]\(([^)#]+)(?:#[^)]+)?\)')) {
    $relative = $match.Groups[1].Value
    if ($relative -notmatch '^[a-z]+://' -and $relative -notmatch '^#') {
      $target = Join-Path $markdownFile.DirectoryName $relative
      if (!(Test-Path -LiteralPath $target)) { Add-ValidationError "Broken relative link in $($markdownFile.Name): $relative" }
    }
  }
}

try {
  [void][ScriptBlock]::Create($manage)
  [void][ScriptBlock]::Create($validateRun)
} catch { Add-ValidationError "PowerShell syntax error: $($_.Exception.Message)" }

$nonAsciiScripts = Get-ChildItem -LiteralPath (Join-Path $SkillRoot "scripts") -File -Filter "*.ps1" | Where-Object {
  (Read-Utf8 $_.FullName) -match '[^\x00-\x7F]'
}
if (@($nonAsciiScripts).Count -gt 0) { Add-ValidationError "PowerShell scripts must remain ASCII for Windows PowerShell 5.1 compatibility." }

if ($errors.Count -gt 0) {
  foreach ($errorText in $errors) { Write-Error $errorText }
  throw "XZQ text audit skill validation failed with $($errors.Count) error(s)."
}

Write-Output "XZQ text audit skill validation passed"
