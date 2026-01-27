<#
.SYNOPSIS
  Build ARM64 and ARM64EC variants (ARM64EC links as ARM64X).
.DESCRIPTION
  Configures and builds both architectures via CMake (unless skipped). The ARM64 build can emit
  a full-path linker response file for diagnostics, while the ARM64EC build links directly with
  /MACHINE:ARM64X.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$SourceDir = ".",
  [ValidateSet("Debug", "Release")][string]$Config = "Release",
  [bool]$EnableOptimizations = $true,
  [string]$OutDir,
  [string]$Generator = "Visual Studio 17 2022",
  [string]$VsWhere,
  [switch]$SkipConfigure,
  [switch]$SkipConfigureArm64,
  [switch]$SkipConfigureArm64EC,
  [switch]$SkipBuild,
  [switch]$SkipBuildArm64,
  [switch]$SkipBuildArm64EC,
  [switch]$SkipProjectBuild,
  [switch]$SkipLink,
  [string]$Def,
  [switch]$KeepArm64Res
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path variable:script:VsEnvCache)) {
  $script:VsEnvCache = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
  $script:VsEnvCurrentArch = $null
  $script:VsEnvCurrentKeys = @()
}

function Resolve-FullPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Base = (Get-Location).Path
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "Path cannot be empty." }
  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Base $Path }
  try {
    [System.IO.Path]::GetFullPath($candidate)
  }
  catch {
    throw ("Unable to resolve '{0}': {1}" -f $Path, $_.Exception.Message)
  }
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Remove-ExistingFile {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (Test-Path $Path) {
    Remove-Item -Path $Path -Force -ErrorAction Stop
  }
}

function Format-LinkToken {
  param([string]$Token)
  if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
  if ($Token.StartsWith("@")) { return $Token }
  if ($Token.StartsWith("/")) { return $Token }
  if ($Token.StartsWith('"') -and $Token.EndsWith('"')) { return $Token }
  if ($Token -match '\s') {
    return ('"{0}"' -f $Token)
  }
  $Token
}

function Import-VsDevEnvironment {
  param(
    [Parameter(Mandatory = $true)][pscustomobject]$VsEnv,
    [Parameter(Mandatory = $true)][string]$TargetArch
  )

  if ($TargetArch -eq "arm64ec") {
    $TargetArch = "arm64"
  }
  $hostArch = if ($VsEnv.HostArch) { $VsEnv.HostArch } else { "x64" }
  $normalizedArch = if ([string]::IsNullOrWhiteSpace($TargetArch)) { "amd64" } else { $TargetArch.ToLowerInvariant() }
  if ($script:VsEnvCurrentArch -eq $normalizedArch) { return }

  
  $envSnapshot = $null
  if (-not ($script:VsEnvCache.ContainsKey($normalizedArch))) {
    Write-Host ("[vsenv] Importing environment for arch {0}" -f $TargetArch) -ForegroundColor Cyan
    $invocation = "call `"$($VsEnv.VsDevCmd)`" -host_arch=$hostArch -arch=$TargetArch && set"
    $envLines = cmd.exe /c $invocation
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw ("VsDevCmd invocation failed with exit code {0} using arch {1}." -f $exitCode, $TargetArch)
    }

    $envSnapshot = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $envLines) {
      if ($line -match "^(.*?)=(.*)$") {
        $name = $matches[1]
        if ($name.StartsWith("=")) { continue }
        $envSnapshot[$name] = $matches[2]
      }
    }
    $script:VsEnvCache[$normalizedArch] = $envSnapshot
  }
  else {
    $envSnapshot = [System.Collections.Hashtable]$script:VsEnvCache[$normalizedArch]
    Write-Host ("[vsenv] Restoring cached environment for arch {0}" -f $TargetArch) -ForegroundColor Cyan
  }

  if ($script:VsEnvCurrentKeys) {
    foreach ($prevKey in $script:VsEnvCurrentKeys) {
      if (-not $envSnapshot.ContainsKey($prevKey)) {
        Remove-Item -Path ("Env:{0}" -f $prevKey) -ErrorAction SilentlyContinue
      }
    }
  }

  foreach ($entry in $envSnapshot.GetEnumerator()) {
    Set-Item -Path ("Env:{0}" -f $entry.Key) -Value $entry.Value -Force
  }

  $script:VsEnvCurrentArch = $normalizedArch
  $script:VsEnvCurrentKeys = @($envSnapshot.Keys)
  $VsEnv | Add-Member -NotePropertyName CurrentArch -NotePropertyValue $TargetArch -Force
}

function Invoke-ExternalCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments,
    [string]$Tag
  )

  $prefix = if ($Tag) { "[{0}] " -f $Tag } else { "" }
  $displaySuffix = if ($Arguments -and $Arguments.Count -gt 0) { " {0}" -f ($Arguments -join ' ') } else { "" }
  Write-Host ("{0}{1}{2}" -f $prefix, $FilePath, $displaySuffix) -ForegroundColor Cyan

  & $FilePath @Arguments
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw ("Command failed with exit code {0}: {1}{2}" -f $exitCode, $FilePath, $displaySuffix)
  }
}

function Get-VsEnvironment {
  param([string]$VsWhereOverride)
  $vswhere = if ($VsWhereOverride) {
    Resolve-FullPath $VsWhereOverride
  }
  else {
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  }
  if (-not (Test-Path $vswhere)) {
    throw ("vswhere.exe not found at '{0}'." -f $vswhere)
  }
  $installPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $installPath) {
    throw "Unable to locate a Visual Studio installation with required C++ tooling."
  }
  $installPath = $installPath.Trim()
  $vsDevCmd = Join-Path $installPath "Common7\Tools\VsDevCmd.bat"
  if (-not (Test-Path $vsDevCmd)) {
    throw ("VsDevCmd.bat not found at '{0}'." -f $vsDevCmd)
  }
  [PSCustomObject]@{
    VsRoot      = $installPath
    VsDevCmd    = $vsDevCmd
    HostArch    = "x64"
    CurrentArch = $null
  }
}

function Configure-CMake {
  param(
    [pscustomobject]$VsEnv,
    [string]$Source,
    [string]$BuildDir,
    [string]$Generator,
    [string]$Arch,
    [string]$Config,
    [string]$LinkRspPath,
    [ValidateSet("LinkRepro", "LinkReproFullPathRsp")][string]$ReproMode = "LinkReproFullPathRsp",
    [bool]$EnableOptimizations
  )

  Import-VsDevEnvironment -VsEnv $VsEnv -TargetArch $Arch
  Ensure-Directory $BuildDir

  $cmakeArgs = New-Object 'System.Collections.Generic.List[string]'
  $cmakeArgs.Add("-S")
  $cmakeArgs.Add($Source)
  $cmakeArgs.Add("-B")
  $cmakeArgs.Add($BuildDir)
  $cmakeArgs.Add("-G")
  $cmakeArgs.Add($Generator)
  $cmakeArgs.Add("-A")
  $cmakeArgs.Add($Arch)

  $configKey = $Config.ToUpperInvariant()
  $linkFlags = New-Object 'System.Collections.Generic.List[string]'

  if ($LinkRspPath) {
    $linkFlagBase = switch ($ReproMode) {
      "LinkRepro" { "/LINKREPRO:$LinkRspPath" }
      default { "/LINKREPROFULLPATHRSP:$LinkRspPath" }
    }
    $linkFlags.Add($linkFlagBase)
  }
  if (-not ($linkFlags -contains "/DEBUG")) {
    $linkFlags.Add("/DEBUG")
  }

  $linkFlags.Add("/STACK:0x40000,0x1000")

  if ($Arch -and $Arch.ToLowerInvariant() -eq "arm64ec") {
    
    $arm64RspPath = $Context.RspPaths.arm64
    if (-not $KeepArm64Res) {
      $arm64RspFiltered = Get-RspWithoutResources -RspPath $arm64RspPath
      if ($arm64RspFiltered -ne $arm64RspPath) {
        Write-Host ("[link] Using filtered ARM64 response: {0}" -f $arm64RspFiltered) -ForegroundColor Yellow
        $arm64RspPath = $arm64RspFiltered
        $Context.RspPaths.arm64 = $arm64RspPath
        foreach ($raw in [System.IO.File]::ReadAllLines($arm64RspPath)) {
          $line = $raw.Trim()
          if ($line) {
            $linkFlags.Add($line)
          }
        }
      }
    }
    $linkFlags.Add("/MACHINE:ARM64X")
  }


  
  if ($EnableOptimizations) 
  {
    $linkFlags.Add("/OPT:REF")
    $linkFlags.Add("/OPT:ICF")
    $linkFlags.Add("/INCREMENTAL:NO")
    $linkFlags.Add("/LTCG")
  }

  $sharedLinkerVar = "CMAKE_SHARED_LINKER_FLAGS"
  $cmakeArgs.Add(('-D{0}={1}' -f $sharedLinkerVar, ($linkFlags -join ' ')))

  
  $cFlagsVar = "CMAKE_C_FLAGS_{0}" -f $configKey
  $cxxFlagsVar = "CMAKE_CXX_FLAGS_{0}" -f $configKey

  $compilerFlags = New-Object 'System.Collections.Generic.List[string]'

  $compilerFlags.Add("/Zi") # Debug info in PDB
  $compilerFlags.Add("/Zo") # Enhanced debug info

  if ($EnableOptimizations) 
  {
    $compilerFlags.Add("/O2") # favor speed
    $compilerFlags.Add("/GL") # whole program optimization
    $compilerFlags.Add("/Gy") # function-level linking
    $compilerFlags.Add("/Gw") # data-level linking
    $compilerFlags.Add("/Zc:inline") # inline conformance
  }

    $cmakeArgs.Add(('-D{0}={1}' -f $cFlagsVar, ($compilerFlags -join ' ')))
    $cmakeArgs.Add(('-D{0}={1}' -f $cxxFlagsVar, ($compilerFlags -join ' ')))
  
  Invoke-ExternalCommand -FilePath "cmake" -Arguments $cmakeArgs.ToArray() -Tag ("configure-{0}" -f $Arch)
}

function Build-CMake {
  param(
    [pscustomobject]$VsEnv,
    [string]$BuildDir,
    [string]$Config,
    [string]$Arch
  )

  Import-VsDevEnvironment -VsEnv $VsEnv -TargetArch $Arch

  $buildArgs = New-Object 'System.Collections.Generic.List[string]'
  $buildArgs.Add("--build")
  $buildArgs.Add($BuildDir)
  $buildArgs.Add("--config")
  $buildArgs.Add($Config)
  $buildArgs.Add("--")
  $buildArgs.Add("/m")

  Invoke-ExternalCommand -FilePath "cmake" -Arguments $buildArgs.ToArray() -Tag ("build-{0}" -f $Arch)
}



function Get-RspWithoutResources {
  param(
    [Parameter(Mandatory = $true)][string]$RspPath
  )

  if (-not (Test-Path $RspPath)) { return $RspPath }

  $lines = [System.IO.File]::ReadAllLines($RspPath)
  $filtered = New-Object 'System.Collections.Generic.List[string]'
  $removed = $false

  foreach ($line in $lines) {
    $trim = $line.Trim()
    if (-not $trim) {
      $filtered.Add($line)
      continue
    }
    if ($trim.StartsWith("#")) {
      $filtered.Add($line)
      continue
    }

    $token = $trim
    if ($token.StartsWith('"') -and $token.EndsWith('"') -and $token.Length -ge 2) {
      $token = $token.Substring(1, $token.Length - 2)
    }
    if ($token.StartsWith("/") -or $token.StartsWith("-")) {
      $filtered.Add($line)
      continue
    }

    $extension = [System.IO.Path]::GetExtension($token)
    if ($extension -and $extension.Equals(".res", [System.StringComparison]::OrdinalIgnoreCase)) {
      $removed = $true
      continue
    }

    $filtered.Add($line)
  }

  if (-not $removed) { return $RspPath }

  $directory = Split-Path $RspPath -Parent
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($RspPath)
  $extension = [System.IO.Path]::GetExtension($RspPath)
  $filteredPath = Join-Path $directory ("{0}-nores{1}" -f $baseName, $extension)
  [System.IO.File]::WriteAllLines($filteredPath, $filtered)
  $filteredPath
}


function Get-OrderedUnique {
  param([Parameter(Mandatory = $true)][System.Collections.IEnumerable]$Values)
  $result = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($value in $Values) {
    if (-not $value) { continue }
    if ($seen.Add($value)) {
      $result.Add($value)
    }
  }
  $result
}


function Resolve-DefinitionOption {
  param(
    [string]$Def,
    [string]$SourceRoot
  )

  if (-not $Def) { return $null }
  $trimmed = $Def.Trim()
  if (-not $trimmed) { return $null }
  if ($trimmed.ToLowerInvariant().StartsWith("/def:")) {
    return $trimmed
  }
  $resolved = Resolve-FullPath $trimmed $SourceRoot
  if (-not (Test-Path $resolved)) {
    throw ("Definition file not found: {0}" -f $resolved)
  }
  '/DEF:"{0}"' -f $resolved
}

function New-BuildContext {
  param(
    [string]$SourceDir,
    [string]$OutDir,
    [string]$Config,
    [string]$Generator,
    [string]$VsWhere
  )

  $sourceRoot = Resolve-FullPath $SourceDir
  if (-not (Test-Path (Join-Path $sourceRoot "CMakeLists.txt"))) {
    throw ("CMakeLists.txt not found under '{0}'." -f $sourceRoot)
  }

  $vsEnv = Get-VsEnvironment -VsWhereOverride $VsWhere

  $buildArm64Root = Join-Path $sourceRoot "build-arm64"
  $buildArm64EcRoot = Join-Path $sourceRoot "build-arm64ec"
  $buildDirs = @{
    arm64   = Join-Path $buildArm64Root $Config
    arm64ec = Join-Path $buildArm64EcRoot $Config
  }

  $arm64Rsp = Join-Path $buildDirs.arm64 ("link-arm64-{0}.rsp" -f $Config.ToLowerInvariant())

  $rspPaths = @{
    arm64   = $arm64Rsp
    arm64ec = $null
  }

  [PSCustomObject]@{
    SourceRoot = $sourceRoot
    Config     = $Config
    Generator  = $Generator
    VsEnv      = $vsEnv
    BuildDirs  = $buildDirs
    RspPaths   = $rspPaths
  }
}

function Write-ContextSummary {
  param([PSCustomObject]$Context)

  Write-Host "Source    : $($Context.SourceRoot)"
  Write-Host "Config    : $($Context.Config)"
  Write-Host "Generator : $($Context.Generator)"
  Write-Host "VS Root   : $($Context.VsEnv.VsRoot)"
}

function Invoke-ConfigureStage {
  param(
    [PSCustomObject]$Context,
    [switch]$SkipConfigure,
    [switch]$SkipConfigureArm64,
    [switch]$SkipConfigureArm64EC,
    [switch]$EnableOptimizations
  )

  if ($SkipConfigure) {
    Write-Host "Configure : skipped"
    return
  }

  if ($SkipConfigureArm64) {
    Write-Host "Configure (ARM64) : skipped"
  }
  else {
    Configure-CMake -VsEnv $Context.VsEnv -Source $Context.SourceRoot -BuildDir $Context.BuildDirs.arm64 -Generator $Context.Generator -Arch "arm64" -Config $Context.Config -LinkRspPath $Context.RspPaths.arm64 -EnableOptimizations:$EnableOptimizations
  }

  if ($SkipConfigureArm64EC) {
    Write-Host "Configure (ARM64EC) : skipped"
  }
  else {
    Configure-CMake -VsEnv $Context.VsEnv -Source $Context.SourceRoot -BuildDir $Context.BuildDirs.arm64ec -Generator $Context.Generator -Arch "arm64ec" -Config $Context.Config -EnableOptimizations:$EnableOptimizations
  }
}

function Invoke-BuildStage {
  param(
    [PSCustomObject]$Context,
    [switch]$SkipBuild,
    [switch]$SkipBuildArm64,
    [switch]$SkipBuildArm64EC
  )

  if ($SkipBuild) {
    Write-Host "Build     : skipped"
    return
  }

  if ($SkipBuildArm64) {
    Write-Host "Build (ARM64) : skipped"
  }
  else {
    Build-CMake -VsEnv $Context.VsEnv -BuildDir $Context.BuildDirs.arm64 -Config $Context.Config -Arch "arm64"
  }

  if ($SkipBuildArm64EC) {
    Write-Host "Build (ARM64EC) : skipped"
  }
  else {
    Build-CMake -VsEnv $Context.VsEnv -BuildDir $Context.BuildDirs.arm64ec -Config $Context.Config -Arch "arm64ec"
  }
}



function Invoke-Main {
  param(
    [string]$SourceDir,
    [string]$OutDir,
    [string]$Config,
    [string]$Generator,
    [string]$VsWhere,
    [switch]$EnableOptimizations,
    [switch]$SkipConfigure,
    [switch]$SkipConfigureArm64,
    [switch]$SkipConfigureArm64EC,
    [switch]$SkipBuild,
    [switch]$SkipBuildArm64,
    [switch]$SkipBuildArm64EC,
    [switch]$SkipProjectBuild,
    [switch]$SkipLink,
    [string]$Def,
    [switch]$KeepArm64Res
  )

  $context = New-BuildContext -SourceDir $SourceDir -OutDir $OutDir -Config $Config -Generator $Generator -VsWhere $VsWhere
  Write-ContextSummary -Context $context

  Invoke-ConfigureStage -Context $context -SkipConfigure:$SkipConfigure -SkipConfigureArm64:$SkipConfigureArm64 -SkipConfigureArm64EC:$SkipConfigureArm64EC -EnableOptimizations:$EnableOptimizations

  $skipProjectBuildEffective = $SkipBuild -or $SkipProjectBuild
  Invoke-BuildStage -Context $context -SkipBuild:$skipProjectBuildEffective -SkipBuildArm64:$SkipBuildArm64 -SkipBuildArm64EC:$SkipBuildArm64EC

}

Invoke-Main `
  -SourceDir $SourceDir `
  -OutDir $OutDir `
  -Config $Config `
  -Generator $Generator `
  -VsWhere $VsWhere `
  -EnableOptimizations:$EnableOptimizations `
  -SkipConfigure:$SkipConfigure `
  -SkipConfigureArm64:$SkipConfigureArm64 `
  -SkipConfigureArm64EC:$SkipConfigureArm64EC `
  -SkipBuild:$SkipBuild `
  -SkipBuildArm64:$SkipBuildArm64 `
  -SkipBuildArm64EC:$SkipBuildArm64EC `
  -SkipProjectBuild:$SkipProjectBuild `
  -SkipLink:$SkipLink `
  -Def $Def `
  -KeepArm64Res:$KeepArm64Res
