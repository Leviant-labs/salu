$ErrorActionPreference = 'Stop'

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit $LASTEXITCODE" }
}

function Find-GitBash {
  if ($IsLinux -or $IsMacOS) {
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($bashCmd) { return $bashCmd.Source }
    return $null
  }

  $candidates = @()
  if ($env:ProgramFiles) {
    $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe')
  }
  $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  if ($programFilesX86) {
    $candidates += (Join-Path $programFilesX86 'Git\bin\bash.exe')
  }

  $gitCmd = Get-Command git -ErrorAction SilentlyContinue
  if ($gitCmd) {
    $gitDir = Split-Path $gitCmd.Source -Parent
    $gitRoot = Split-Path $gitDir -Parent
    $candidates += (Join-Path $gitRoot 'bin\bash.exe')
    $candidates += (Join-Path $gitDir 'bash.exe')

    $execPath = (& git --exec-path 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $execPath) {
      $execDir = $execPath.Trim()
      if ($execDir) {
        $candidates += (Join-Path $execDir 'bash.exe')
        $cur = $execDir
        for ($i = 0; $i -lt 4 -and $cur; $i++) {
          $candidates += (Join-Path $cur 'bin\bash.exe')
          $candidates += (Join-Path $cur 'usr\bin\bash.exe')
          $cur = Split-Path $cur -Parent
        }
      }
    }
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return $candidate
    }
  }

  return $null
}

function Invoke-BoundaryCheckFallback {
  $targets = @()
  if (Test-Path -LiteralPath 'packages/salu_core/lib' -PathType Container) {
    $targets += Get-ChildItem -Path 'packages/salu_core/lib' -File -Recurse
  }
  if (Test-Path -LiteralPath 'packages/salu_core/pubspec.yaml' -PathType Leaf) {
    $targets += Get-Item -LiteralPath 'packages/salu_core/pubspec.yaml'
  }
  if (-not $targets) {
    throw 'Boundary check failed: packages/salu_core/lib and packages/salu_core/pubspec.yaml could not be scanned'
  }

  $rules = @(
    @{ Label = 'salu_core must not import Flutter'; Pattern = 'package:flutter' },
    @{ Label = 'salu_core must not import a database driver'; Pattern = 'package:(drift|sqlite3|sqflite|hive|isar)' },
    @{ Label = 'salu_core must not import an HTTP client'; Pattern = 'package:(http|dio|web_socket_channel)' },
    @{ Label = 'salu_core must not use dart:io'; Pattern = 'dart:io' },
    @{ Label = 'salu_core must not import salu_data or the app'; Pattern = 'package:(salu_data|salu/)' }
  )

  $failed = $false
  foreach ($rule in $rules) {
    $hits = $targets | Select-String -Pattern $rule.Pattern
    if ($hits) {
      Write-Host "FAIL: $($rule.Label)"
      foreach ($hit in $hits) {
        Write-Host "$($hit.Path):$($hit.LineNumber):$($hit.Line)"
      }
      $failed = $true
    } else {
      Write-Host "ok: $($rule.Label)"
    }
  }
  if ($failed) {
    throw 'Boundary check failed'
  }
}

$pin = (Get-Content "$PSScriptRoot/flutter-version.txt" -Raw).Trim()
$versionOutput = & flutter --version --machine
if ($LASTEXITCODE -ne 0) { throw "flutter --version --machine failed with exit $LASTEXITCODE" }
$actual = ($versionOutput | ConvertFrom-Json).frameworkVersion
if ($actual -ne $pin) { throw "Flutter $pin required; found $actual" }

$repoRoot = Split-Path $PSScriptRoot -Parent
$origLocation = Get-Location

try {
  Set-Location $repoRoot

  Push-Location 'packages/salu_core'
  try {
    Invoke-Checked 'dart' @('pub', 'get', '--enforce-lockfile')
  } finally {
    Pop-Location
  }

  Push-Location 'packages/salu_data'
  try {
    Invoke-Checked 'dart' @('pub', 'get', '--enforce-lockfile')
  } finally {
    Pop-Location
  }

  Push-Location 'app'
  try {
    Invoke-Checked 'flutter' @('pub', 'get', '--enforce-lockfile')
  } finally {
    Pop-Location
  }

  Push-Location 'packages/salu_data'
  try {
    Invoke-Checked 'dart' @('run', 'build_runner', 'build')
  } finally {
    Pop-Location
  }

  $gitBash = Find-GitBash
  if ($gitBash) {
    Invoke-Checked $gitBash @('tool/check_boundaries.sh')
  } else {
    Invoke-BoundaryCheckFallback
  }

  $formatRoots = @(
    'packages/salu_core/lib',
    'packages/salu_core/test',
    'packages/salu_data/lib',
    'packages/salu_data/test',
    'app/lib',
    'app/test',
    'tool'
  )
  $formatFiles = @(foreach ($root in $formatRoots) {
    if (Test-Path -LiteralPath $root) {
      Get-ChildItem -Path $root -Filter '*.dart' -File -Recurse |
        Where-Object {
          $_.Name -notlike '*.g.dart' -and
          $_.FullName -notmatch '[\\/](\.dart_tool|build|android|ios|linked_list_merge)[\\/]'
        } |
        ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName) }
    }
  })
  if ($formatFiles.Count -gt 0) {
    $batch = [System.Collections.Generic.List[string]]::new()
    $batchChars = 0
    foreach ($file in $formatFiles) {
      if ($batch.Count -gt 0 -and ($batchChars + $file.Length + 3) -gt 4000) {
        Invoke-Checked 'dart' (@('format', '--output=none', '--set-exit-if-changed') + $batch.ToArray())
        $batch.Clear()
        $batchChars = 0
      }
      $batch.Add($file)
      $batchChars += $file.Length + 3
    }
    if ($batch.Count -gt 0) {
      Invoke-Checked 'dart' (@('format', '--output=none', '--set-exit-if-changed') + $batch.ToArray())
    }
  }

  Push-Location 'packages/salu_core'
  try {
    Invoke-Checked 'dart' @('analyze')
    Invoke-Checked 'dart' @('test')
  } finally {
    Pop-Location
  }

  Push-Location 'packages/salu_data'
  try {
    Invoke-Checked 'dart' @('analyze')
    Invoke-Checked 'dart' @('test')
  } finally {
    Pop-Location
  }

  Push-Location 'app'
  try {
    Invoke-Checked 'flutter' @('analyze')
    Invoke-Checked 'flutter' @('test', '--no-pub')
  } finally {
    Pop-Location
  }
} finally {
  Set-Location $origLocation
}
