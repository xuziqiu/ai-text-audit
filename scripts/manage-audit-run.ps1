param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Init", "Status", "SetStage", "SetStatus", "AddLimitation", "VerifyResume")]
  [string]$Action,

  [Parameter(Mandatory = $true)]
  [string]$RunPath,

  [string]$SourcePath,
  [ValidateSet("compact", "full_trace")]
  [string]$ArtifactProfile = "compact",
  [ValidateSet("when_material", "included", "skipped")]
  [string]$FactCheck = "when_material",
  [string]$RequestedScope = "complete independent text audit",

  [ValidateSet("intake", "first_read", "reconstruction", "open_scan", "focused_review", "fact_check", "synthesis", "report", "validation")]
  [string]$Stage,
  [ValidateSet("pending", "in_progress", "completed", "partial", "needs_input", "not_applicable", "failed")]
  [string]$StageState,
  [ValidateSet("in_progress", "partial", "needs_input", "superseded", "failed", "completed")]
  [string]$RunStatus,
  [string]$Note = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$SkillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

function Get-IsoTime { (Get-Date).ToUniversalTime().ToString("o") }

function Get-FileSha256([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
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

function Write-JsonUtf8([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Read-Manifest([string]$Root) {
  $path = Join-Path $Root "run.json"
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Run manifest not found: $path" }
  Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Manifest([string]$Root, $Manifest) {
  $Manifest.updated_at = Get-IsoTime
  Write-JsonUtf8 (Join-Path $Root "run.json") $Manifest
}

function Add-History($Manifest, [string]$Event, [string]$HistoryStage, [string]$From, [string]$To, [string]$HistoryNote) {
  $entry = [PSCustomObject][ordered]@{
    at = Get-IsoTime
    event = $Event
    stage = if ($HistoryStage) { $HistoryStage } else { $null }
    from = if ($From) { $From } else { $null }
    to = if ($To) { $To } else { $null }
    note = $HistoryNote
  }
  $Manifest.history = @($Manifest.history) + $entry
}

function Get-SafeArtifactPath([string]$Root, [string]$Relative) {
  if ([string]::IsNullOrWhiteSpace($Relative)) { throw "Artifact path is empty." }
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  $candidate = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
  if (!$candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Artifact path escapes the run directory: $Relative"
  }
  $candidate
}

function Test-SubstantiveFile([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  return $text.Trim().Length -ge 40
}

function Set-HashProperty($Manifest, [string]$Relative, [string]$Hash) {
  if ($null -eq $Manifest.artifact_hashes) {
    $Manifest | Add-Member -MemberType NoteProperty -Name artifact_hashes -Value ([PSCustomObject]@{})
  }
  $property = $Manifest.artifact_hashes.PSObject.Properties[$Relative]
  if ($null -eq $property) {
    $Manifest.artifact_hashes | Add-Member -MemberType NoteProperty -Name $Relative -Value $Hash
  } else {
    $property.Value = $Hash
  }
}

function Get-StageArtifactNames($Manifest, [string]$StageName) {
  $profile = [string]$Manifest.artifact_profile
  switch ($StageName) {
    "first_read" { @([string]$Manifest.artifacts.initial_core_judgment) }
    "reconstruction" {
      if ($profile -eq "full_trace") { @("working/01-writing-structure.md", "working/02-content-function-map.md") } else { @() }
    }
    "open_scan" { if ($profile -eq "full_trace") { @("working/03-open-scan.md") } else { @() } }
    "focused_review" { if ($profile -eq "full_trace") { @("working/04-focused-review.md") } else { @() } }
    "fact_check" { @([string]$Manifest.artifacts.sources) }
    "synthesis" { @([string]$Manifest.artifacts.synthesis) }
    "report" {
      $files = @([string]$Manifest.artifacts.scorecard, [string]$Manifest.artifacts.report)
      if ($profile -eq "full_trace") { $files += @("working/05-report-coverage-draft.md", "working/06-report-editorial-review.md") }
      $files
    }
    "validation" { @([string]$Manifest.artifacts.validation) }
    default { @() }
  }
}

function Assert-StagePrerequisites($Manifest, [string]$StageName) {
  switch ($StageName) {
    "reconstruction" { if ($Manifest.stages.first_read -ne "completed") { throw "Cannot complete reconstruction before first_read is completed." } }
    "open_scan" { if ($Manifest.stages.reconstruction -ne "completed") { throw "Cannot complete open_scan before reconstruction is completed." } }
    "focused_review" { if ($Manifest.stages.open_scan -ne "completed") { throw "Cannot complete focused_review before open_scan is completed." } }
    "synthesis" {
      if ($Manifest.stages.focused_review -ne "completed") { throw "Cannot complete synthesis before focused_review is completed." }
      if ($Manifest.stages.fact_check -notin @("completed", "partial", "not_applicable")) { throw "Cannot complete synthesis before fact_check is resolved." }
    }
    "report" { if ($Manifest.stages.synthesis -ne "completed") { throw "Cannot complete report before synthesis is completed." } }
    "validation" { if ($Manifest.stages.report -ne "completed") { throw "Cannot complete validation before report is completed." } }
  }
}

$runFullPath = [IO.Path]::GetFullPath($RunPath)

switch ($Action) {
  "Init" {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw "Init requires -SourcePath." }
    $sourceFull = [IO.Path]::GetFullPath($SourcePath)
    if (!(Test-Path -LiteralPath $sourceFull -PathType Leaf)) { throw "Source file not found: $sourceFull" }
    if (Test-Path -LiteralPath $runFullPath) {
      if ((Get-ChildItem -LiteralPath $runFullPath -Force | Measure-Object).Count -gt 0) { throw "Run directory already exists and is not empty: $runFullPath" }
    } else {
      New-Item -ItemType Directory -Path $runFullPath -Force | Out-Null
    }

    $extension = [IO.Path]::GetExtension($sourceFull)
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = ".txt" }
    $frozenName = "source$extension"
    $frozenPath = Join-Path $runFullPath $frozenName
    Copy-Item -LiteralPath $sourceFull -Destination $frozenPath
    [IO.File]::WriteAllText((Join-Path $runFullPath "working.md"), "# Audit Working Index`r`n`r`n", [Text.UTF8Encoding]::new($false))

    if ($ArtifactProfile -eq "full_trace") {
      New-Item -ItemType Directory -Path (Join-Path $runFullPath "working") -Force | Out-Null
      New-Item -ItemType Directory -Path (Join-Path $runFullPath "working\investigations") -Force | Out-Null
      $initialRelative = "working/00-initial-core-judgment.md"
    } else {
      $initialRelative = "initial-core-judgment.md"
    }

    $now = Get-IsoTime
    $sourceHash = Get-FileSha256 $frozenPath
    $factState = if ($FactCheck -eq "skipped") { "not_applicable" } else { "pending" }
    $limitations = @()
    if ($FactCheck -eq "skipped") { $limitations += "External fact checking was explicitly skipped." }
    $history = @([PSCustomObject][ordered]@{ at = $now; event = "run_initialized"; stage = "intake"; from = $null; to = "completed"; note = "Source frozen and identities recorded." })
    if ($FactCheck -eq "skipped") {
      $history += [PSCustomObject][ordered]@{ at = $now; event = "stage_changed"; stage = "fact_check"; from = "pending"; to = "not_applicable"; note = "External fact checking was explicitly skipped." }
    }

    $manifest = [ordered]@{
      schema_version = 1
      run_id = "XTA-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$($sourceHash.Substring(0, 8))"
      created_at = $now
      updated_at = $now
      mode = "durable"
      artifact_profile = $ArtifactProfile
      status = "in_progress"
      scope = [ordered]@{ requested = $RequestedScope; fact_check = $FactCheck }
      source = [ordered]@{ path = $frozenName; sha256 = $sourceHash }
      skill = [ordered]@{ path = $SkillRoot; sha256 = Get-DirectorySha256 $SkillRoot }
      scoring = [ordered]@{
        version = "xzq-text-audit-score-v1"
        scale = "0-10"
        weights = [ordered]@{
          task_fulfillment = 25; evidence_grounding = 20; reasoning_explanation = 20;
          structure_organization = 12; language_expression = 10; perspective_boundary = 13
        }
      }
      stages = [ordered]@{
        intake = "completed"; first_read = "pending"; reconstruction = "pending"; open_scan = "pending";
        focused_review = "pending"; fact_check = $factState; synthesis = "pending"; report = "pending"; validation = "pending"
      }
      artifacts = [ordered]@{
        working_notes = "working.md"; initial_core_judgment = $initialRelative;
        trace_dir = if ($ArtifactProfile -eq "full_trace") { "working" } else { $null };
        sources = "sources.md"; synthesis = "synthesis.md"; scorecard = "scorecard.json";
        report = "report.md"; validation = "validation.md"
      }
      artifact_hashes = [ordered]@{}
      limitations = $limitations
      history = $history
    }
    Write-JsonUtf8 (Join-Path $runFullPath "run.json") $manifest
    Write-Output "Initialized XZQ text audit run: $runFullPath"
    break
  }

  "Status" {
    $manifest = Read-Manifest $runFullPath
    [PSCustomObject]@{
      RunId = $manifest.run_id; Status = $manifest.status; Profile = $manifest.artifact_profile;
      FirstRead = $manifest.stages.first_read; Reconstruction = $manifest.stages.reconstruction;
      OpenScan = $manifest.stages.open_scan; FocusedReview = $manifest.stages.focused_review;
      FactCheck = $manifest.stages.fact_check; Synthesis = $manifest.stages.synthesis;
      Report = $manifest.stages.report; Validation = $manifest.stages.validation;
      Limitations = @($manifest.limitations).Count
    }
    break
  }

  "SetStage" {
    if (!$Stage -or !$StageState) { throw "SetStage requires -Stage and -StageState." }
    if ($StageState -in @("partial", "needs_input", "not_applicable", "failed") -and [string]::IsNullOrWhiteSpace($Note)) {
      throw "Stage state '$StageState' requires a non-empty -Note."
    }
    $manifest = Read-Manifest $runFullPath
    if ($StageState -eq "completed") {
      Assert-StagePrerequisites $manifest $Stage
      if ($Stage -eq "validation") {
        $validatorPath = Join-Path $SkillRoot "scripts\validate-audit-run.ps1"
        & $validatorPath -RunPath $runFullPath
      }
      if ($Stage -eq "open_scan" -and $manifest.artifact_profile -eq "full_trace") {
        $scanPath = Get-SafeArtifactPath $runFullPath "working/03-open-scan.md"
        if (!(Test-Path -LiteralPath $scanPath -PathType Leaf)) { throw "Cannot complete open_scan before working/03-open-scan.md exists." }
        $scanText = Get-Content -LiteralPath $scanPath -Raw -Encoding UTF8
        $observationIds = @([regex]::Matches($scanText, '(?im)\bOBS-(\d{3,})\b') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)
        if ($observationIds.Count -lt 50) { throw "Cannot complete open_scan before it contains at least 50 unique OBS identifiers." }
      }
      foreach ($relative in @(Get-StageArtifactNames $manifest $Stage)) {
        $artifactPath = Get-SafeArtifactPath $runFullPath $relative
        if (!(Test-SubstantiveFile $artifactPath)) { throw "Cannot complete $Stage before a substantive artifact exists: $relative" }
        Set-HashProperty $manifest $relative (Get-FileSha256 $artifactPath)
      }
    }
    if ($Stage -eq "fact_check" -and $StageState -eq "partial") {
      $relative = [string]$manifest.artifacts.sources
      $artifactPath = Get-SafeArtifactPath $runFullPath $relative
      if (!(Test-SubstantiveFile $artifactPath)) { throw "Cannot partially complete fact_check before sources.md is substantive." }
      Set-HashProperty $manifest $relative (Get-FileSha256 $artifactPath)
    }
    $old = [string]$manifest.stages.$Stage
    $manifest.stages.$Stage = $StageState
    if ($StageState -in @("partial", "needs_input", "failed") -and $Note -notin @($manifest.limitations)) { $manifest.limitations += $Note }
    Add-History $manifest "stage_changed" $Stage $old $StageState $Note
    Save-Manifest $runFullPath $manifest
    Write-Output "Stage '$Stage': $old -> $StageState"
    break
  }

  "SetStatus" {
    if (!$RunStatus) { throw "SetStatus requires -RunStatus." }
    if ($RunStatus -in @("partial", "needs_input", "superseded", "failed") -and [string]::IsNullOrWhiteSpace($Note)) {
      throw "Run status '$RunStatus' requires a non-empty -Note."
    }
    $manifest = Read-Manifest $runFullPath
    if ($RunStatus -eq "completed") {
      if ($manifest.stages.validation -ne "completed") { throw "Cannot complete run before validation is completed." }
      foreach ($required in @("first_read", "reconstruction", "open_scan", "focused_review", "synthesis", "report", "validation")) {
        if ($manifest.stages.$required -ne "completed") { throw "Cannot complete run while stage '$required' is not completed." }
      }
      if ($manifest.stages.fact_check -notin @("completed", "partial", "not_applicable")) { throw "Cannot complete run before fact_check is resolved." }
      $validatorPath = Join-Path $SkillRoot "scripts\validate-audit-run.ps1"
      & $validatorPath -RunPath $runFullPath
    }
    $old = [string]$manifest.status
    $manifest.status = $RunStatus
    if ($RunStatus -in @("partial", "needs_input", "failed") -and $Note -notin @($manifest.limitations)) { $manifest.limitations += $Note }
    Add-History $manifest "status_changed" $null $old $RunStatus $Note
    Save-Manifest $runFullPath $manifest
    Write-Output "Run status: $old -> $RunStatus"
    break
  }

  "AddLimitation" {
    if ([string]::IsNullOrWhiteSpace($Note)) { throw "AddLimitation requires -Note." }
    $manifest = Read-Manifest $runFullPath
    if ($Note -notin @($manifest.limitations)) { $manifest.limitations += $Note }
    Add-History $manifest "limitation_added" $null $null $null $Note
    Save-Manifest $runFullPath $manifest
    Write-Output "Limitation recorded."
    break
  }

  "VerifyResume" {
    $manifest = Read-Manifest $runFullPath
    $sourcePath = Get-SafeArtifactPath $runFullPath ([string]$manifest.source.path)
    $currentSourceHash = Get-FileSha256 $sourcePath
    if ($currentSourceHash -ne [string]$manifest.source.sha256) { throw "Source hash mismatch; stop automatic resume." }
    $currentSkillHash = Get-DirectorySha256 $SkillRoot
    if ($currentSkillHash -ne [string]$manifest.skill.sha256) { throw "Skill hash mismatch; stop automatic resume." }
    foreach ($property in $manifest.artifact_hashes.PSObject.Properties) {
      $artifactPath = Get-SafeArtifactPath $runFullPath $property.Name
      if ((Get-FileSha256 $artifactPath) -ne [string]$property.Value) { throw "Frozen artifact hash mismatch: $($property.Name)" }
    }
    Write-Output "Resume verification passed."
    break
  }
}
