<#
.SYNOPSIS
  Build ARM64 and ARM64EC variants and link an ARM64X hybrid DLL.
.DESCRIPTION
  Configures and builds both architectures via CMake (unless skipped), captures linker response
  files (ARM64 via /LinkReproFullPathRsp, ARM64EC via /LinkRepro), normalizes the ARM64EC response
  file to absolute paths, and links them into an ARM64X hybrid DLL through link.exe
  (unless linking is skipped).
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$SourceDir = ".",
  [Parameter(Mandatory = $true)][string]$TargetDll,
  [ValidateSet("Debug","Release")][string]$Config = "Release",
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
  [string]$Def
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Base = (Get-Location).Path
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "Path cannot be empty." }
  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Base $Path }
  try {
    [System.IO.Path]::GetFullPath($candidate)
  } catch {
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

function Resolve-SystemLibraries {
  param(
    [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Inputs,
    [Parameter(Mandatory = $true)][string[]]$LibraryNames
  )

  $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($item in $Inputs) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    $ext = [System.IO.Path]::GetExtension($item)
    if ($ext -and $ext.Equals(".lib", [System.StringComparison]::OrdinalIgnoreCase)) {
      $name = [System.IO.Path]::GetFileNameWithoutExtension($item)
      if ($name) { $existing.Add($name) | Out-Null }
      $dir = Split-Path $item -Parent
      if ($dir) { $directories.Add($dir) | Out-Null }
    }
  }

  $resolved = New-Object System.Collections.Generic.List[string]
  foreach ($libName in $LibraryNames) {
    if ($existing.Contains($libName)) { continue }
    $targetFile = "{0}.lib" -f $libName
    $found = $false
    foreach ($dir in $directories) {
      $candidate = Join-Path $dir $targetFile
      if (Test-Path $candidate) {
        $resolved.Add($candidate)
        $found = $true
        break
      }
    }
    if (-not $found) {
      foreach ($dir in $directories) {
        $parent = Split-Path $dir -Parent
        if (-not $parent) { continue }
        $candidate = Join-Path $parent $targetFile
        if (Test-Path $candidate) {
          $resolved.Add($candidate)
          $found = $true
          break
        }
      }
    }
  }

  $resolved
}

function Invoke-VsCommand {
  param(
    [Parameter(Mandatory = $true)][string]$VsDevCmd,
    [Parameter(Mandatory = $true)][string]$CommandLine,
    [string]$Arch = "amd64",
    [string]$Tag
  )
  $archArg = if ([string]::IsNullOrWhiteSpace($Arch)) { "" } else { "-arch=$Arch" }
  $prefix = if ($Tag) { "[{0}] " -f $Tag } else { "" }
  Write-Host ("{0}{1}" -f $prefix, $CommandLine) -ForegroundColor Cyan
  $wrapped = "call `"$VsDevCmd`" -host_arch=amd64 $archArg >nul && $CommandLine"
  $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/d","/s","/c",$wrapped -NoNewWindow -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    throw ("Command failed with exit code {0}: {1}" -f $proc.ExitCode, $CommandLine)
  }
}

function Get-VsEnvironment {
  param([string]$VsWhereOverride)
  $vswhere = if ($VsWhereOverride) {
    Resolve-FullPath $VsWhereOverride
  } else {
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
    VsRoot   = $installPath
    VsDevCmd = $vsDevCmd
  }
}

function Configure-CMake {
  param(
    [string]$VsDevCmd,
    [string]$Source,
    [string]$BuildDir,
    [string]$Generator,
    [string]$Arch,
    [string]$Config,
    [string]$LinkRspPath,
    [ValidateSet("LinkRepro","LinkReproFullPathRsp")][string]$ReproMode = "LinkReproFullPathRsp"
  )
  Ensure-Directory $BuildDir
  $args = @(
    "cmake",
    "-S `"$Source`"",
    "-B `"$BuildDir`"",
    "-G `"$Generator`"",
    "-A $Arch"
  )
  if ($LinkRspPath) {
    $configKey = $Config.ToUpperInvariant()
    $flagVar = "CMAKE_SHARED_LINKER_FLAGS_{0}" -f $configKey
    $flagValue = switch ($ReproMode) {
      "LinkRepro" { "/LINKREPRO:$LinkRspPath" }
      default { "/LINKREPROFULLPATHRSP:$LinkRspPath" }
    }
    $args += ('-D {0}={1}' -f $flagVar, $flagValue)
  }
  $cmd = $args -join ' '
  Invoke-VsCommand -VsDevCmd $VsDevCmd -CommandLine $cmd -Arch "amd64" -Tag ("configure-{0}" -f $Arch)
}

function Build-CMake {
  param(
    [string]$VsDevCmd,
    [string]$BuildDir,
    [string]$Config,
    [string]$Target,
    [string]$Arch
  )
  $cmd = "cmake --build `"$BuildDir`" --config $Config --target $Target -- /m"
  $vsArch = "amd64"
  Invoke-VsCommand -VsDevCmd $VsDevCmd -CommandLine $cmd -Arch $vsArch -Tag ("build-{0}" -f $Arch)
}

function Parse-LinkRsp {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path $Path)) {
    throw ("Linker response file not found: {0}" -f $Path)
  }
  $options = New-Object System.Collections.Generic.List[string]
  $libPaths = New-Object System.Collections.Generic.List[string]
  $delayLoads = New-Object System.Collections.Generic.List[string]
  $inputs = New-Object System.Collections.Generic.List[string]
  $def = $null

  foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
    $token = $raw.Trim()
    if (-not $token) { continue }
    if ($token.Length -ge 2 -and $token.StartsWith('"') -and $token.EndsWith('"')) {
      $token = $token.Substring(1, $token.Length - 2)
    }
    if ($token.StartsWith("#")) { continue }
    if ($token.StartsWith("/")) {
      $lower = $token.ToLowerInvariant()
      if ($lower.StartsWith("/def:")) {
        $def = $token
        continue
      }
      if ($lower.StartsWith("/libpath:")) {
        $libPaths.Add($token)
        continue
      }
      if ($lower.StartsWith("/delayload:")) {
        $delayLoads.Add($token)
        continue
      }
      $options.Add($token)
      continue
    }
    $inputs.Add($token)
  }

  [PSCustomObject]@{
    Path       = $Path
    Def        = $def
    LibPaths   = $libPaths
    DelayLoads = $delayLoads
    Options    = $options
    Inputs     = $inputs
  }
}

function Convert-LinkRspTokenToFullPath {
  param(
    [string]$Token,
    [string]$BaseDir
  )

  if ([string]::IsNullOrWhiteSpace($Token)) { return $Token }
  $trim = $Token.Trim()
  $quoted = $false
  if ($trim.StartsWith('"') -and $trim.EndsWith('"') -and $trim.Length -ge 2) {
    $quoted = $true
    $trim = $trim.Substring(1, $trim.Length - 2)
  }

  if ($trim -match '^[.]{1,2}[\\/].*') {
    $resolved = Resolve-FullPath -Path $trim -Base $BaseDir
    return ('"{0}"' -f $resolved)
  }

  if ($quoted) {
    return ('"{0}"' -f $trim)
  }
  $Token.Trim()
}

function Convert-LinkRspLineToFullPaths {
  param(
    [string]$Line,
    [string]$BaseDir
  )

  if ($null -eq $Line) { return $Line }
  $trim = $Line.Trim()
  if (-not $trim) { return $Line }
  if ($trim.StartsWith("#")) { return $Line }

  if ($trim.StartsWith("@")) {
    $token = $trim.Substring(1)
    $converted = Convert-LinkRspTokenToFullPath -Token $token -BaseDir $BaseDir
    return ("@{0}" -f $converted)
  }

  if ($trim.StartsWith("/")) {
    $colonIndex = $trim.IndexOf(":")
    if ($colonIndex -gt 0 -and $colonIndex -lt ($trim.Length - 1)) {
      $prefix = $trim.Substring(0, $colonIndex + 1)
      $suffix = $trim.Substring($colonIndex + 1)
      $convertedSuffix = Convert-LinkRspTokenToFullPath -Token $suffix -BaseDir $BaseDir
      return ("{0}{1}" -f $prefix, $convertedSuffix)
    }
    return $trim
  }

  Convert-LinkRspTokenToFullPath -Token $trim -BaseDir $BaseDir
}

function Convert-LinkRspToFullPaths {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRsp,
    [Parameter(Mandatory = $true)][string]$OutputRsp
  )

  if (-not (Test-Path $SourceRsp)) {
    throw ("Link response file not found: {0}" -f $SourceRsp)
  }

  $baseDir = Split-Path $SourceRsp -Parent
  Ensure-Directory (Split-Path $OutputRsp -Parent)

  $converted = New-Object System.Collections.Generic.List[string]
  foreach ($line in [System.IO.File]::ReadAllLines($SourceRsp)) {
    $converted.Add((Convert-LinkRspLineToFullPaths -Line $line -BaseDir $baseDir))
  }
  [System.IO.File]::WriteAllLines($OutputRsp, $converted)
  $OutputRsp
}

function Ensure-Arm64EcFullRsp {
  param([PSCustomObject]$Context)

  $currentPath = $Context.RspPaths.arm64ec
  if ([string]::IsNullOrWhiteSpace($currentPath)) {
    throw "ARM64EC response path is not set."
  }

  $fileName = [System.IO.Path]::GetFileName($currentPath)
  if ($fileName -and $fileName.Equals("link-full-paths.rsp", [System.StringComparison]::OrdinalIgnoreCase)) {
    if (-not (Test-Path $currentPath)) {
      throw ("Expected ARM64EC response file not found: {0}" -f $currentPath)
    }
    return $currentPath
  }

  $dir = Split-Path $currentPath -Parent
  if (-not (Test-Path $currentPath)) {
    $existingFull = Join-Path $dir "link-full-paths.rsp"
    if (Test-Path $existingFull) {
      $Context.RspPaths.arm64ec = $existingFull
      return $existingFull
    }
    throw ("ARM64EC response file not found: {0}" -f $currentPath)
  }

  $target = Join-Path $dir "link-full-paths.rsp"
  Convert-LinkRspToFullPaths -SourceRsp $currentPath -OutputRsp $target | Out-Null
  $Context.RspPaths.arm64ec = $target
  $target
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

function Merge-LinkData {
  param(
    [PSCustomObject]$Arm64Ec,
    [PSCustomObject]$Arm64,
    [string]$DefOverride
  )

  $def = $null
  if ($DefOverride) {
    $def = $DefOverride
  } elseif ($Arm64Ec.Def) {
    $def = $Arm64Ec.Def
  } elseif ($Arm64.Def) {
    $def = $Arm64.Def
  }
  if (-not $def) {
    throw "No module definition file (.def) found in linker inputs. Supply one via -Def."
  }

  $libBag = New-Object System.Collections.Generic.List[string]
  foreach ($item in $Arm64Ec.LibPaths) { $libBag.Add($item) }
  foreach ($item in $Arm64.LibPaths) { $libBag.Add($item) }
  $libPaths = Get-OrderedUnique $libBag

  $delayBag = New-Object System.Collections.Generic.List[string]
  foreach ($item in $Arm64Ec.DelayLoads) { $delayBag.Add($item) }
  foreach ($item in $Arm64.DelayLoads) { $delayBag.Add($item) }
  $delayLoads = Get-OrderedUnique $delayBag

  $optionBag = New-Object System.Collections.Generic.List[string]
  foreach ($opt in $Arm64Ec.Options) { $optionBag.Add($opt) }
  foreach ($opt in $Arm64.Options) { $optionBag.Add($opt) }

  $filteredOptions = New-Object System.Collections.Generic.List[string]
  foreach ($opt in $optionBag) {
    if ([string]::IsNullOrWhiteSpace($opt)) { continue }
    $lower = $opt.ToLowerInvariant()
    if ($lower.StartsWith("/out") -or
        $lower.StartsWith("/implib") -or
        $lower.StartsWith("/pdb") -or
        $lower.StartsWith("/machine") -or
        $lower -eq "/dll" -or
        $lower -eq "/nologo") {
      continue
    }
    $filteredOptions.Add($opt)
  }
  $options = Get-OrderedUnique $filteredOptions

  $inputBag = New-Object System.Collections.Generic.List[string]
  foreach ($item in $Arm64Ec.Inputs) { $inputBag.Add($item) }
  foreach ($item in $Arm64.Inputs) { $inputBag.Add($item) }

  $inputs = Get-OrderedUnique $inputBag

  $extraLibs = Resolve-SystemLibraries -Inputs $inputs -LibraryNames @("shlwapi")

  [PSCustomObject]@{
    Def        = $def
    LibPaths   = $libPaths
    DelayLoads = $delayLoads
    Options    = $options
    Inputs     = $inputs
    ExtraLibs  = $extraLibs
  }
}

function Resolve-TargetArtifacts {
  param(
    [string]$TargetDll,
    [string]$OutDir,
    [string]$SourceDir,
    [string]$Config
  )

  $resolvedOutDir = if ($OutDir) {
    Resolve-FullPath $OutDir $SourceDir
  } else {
    $null
  }

  if ([System.IO.Path]::IsPathRooted($TargetDll)) {
    $dllPath = Resolve-FullPath $TargetDll
    $dllDir = Split-Path $dllPath -Parent
    if ($resolvedOutDir -and ($dllDir -ne $resolvedOutDir)) {
      throw ("TargetDll directory '{0}' must match OutDir '{1}'." -f $dllDir, $resolvedOutDir)
    }
  } else {
    if (-not $resolvedOutDir) {
      $resolvedOutDir = Join-Path $SourceDir ("out-arm64x\{0}" -f $Config)
    }
    Ensure-Directory $resolvedOutDir
    $dllPath = Resolve-FullPath (Join-Path $resolvedOutDir $TargetDll)
    $dllDir = Split-Path $dllPath -Parent
  }

  $ext = [System.IO.Path]::GetExtension($dllPath)
  if ([string]::IsNullOrWhiteSpace($ext)) {
    $dllPath = $dllPath + ".dll"
  } elseif ($ext.ToLowerInvariant() -ne ".dll") {
    throw "TargetDll must end with the .dll extension."
  }

  $dllDir = Split-Path $dllPath -Parent
  if (-not $resolvedOutDir) { $resolvedOutDir = $dllDir }
  if ($dllDir -ne $resolvedOutDir) {
    throw ("TargetDll directory '{0}' must match OutDir '{1}'." -f $dllDir, $resolvedOutDir)
  }
  Ensure-Directory $dllDir
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($dllPath)

  [PSCustomObject]@{
    OutDir    = $resolvedOutDir
    Directory = $dllDir
    Dll       = $dllPath
    Pdb       = Join-Path $dllDir ($baseName + ".pdb")
    Lib       = Join-Path $dllDir ($baseName + ".lib")
    Target    = $baseName
  }
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
    [string]$TargetDll,
    [string]$OutDir,
    [string]$Config,
    [string]$Generator,
    [string]$VsWhere
  )

  $sourceRoot = Resolve-FullPath $SourceDir
  if (-not (Test-Path (Join-Path $sourceRoot "CMakeLists.txt"))) {
    throw ("CMakeLists.txt not found under '{0}'." -f $sourceRoot)
  }

  $targets = Resolve-TargetArtifacts -TargetDll $TargetDll -OutDir $OutDir -SourceDir $sourceRoot -Config $Config
  $vsEnv = Get-VsEnvironment -VsWhereOverride $VsWhere

  $buildDirs = @{
    arm64   = Join-Path $sourceRoot "build-arm64"
    arm64ec = Join-Path $sourceRoot "build-arm64ec"
  }

  $arm64Rsp = Join-Path $buildDirs.arm64 ("link-arm64-{0}.rsp" -f $Config.ToLowerInvariant())
  $arm64EcReproDir = Join-Path $buildDirs.arm64ec ("linkrepro-arm64ec-{0}" -f $Config.ToLowerInvariant())
  $arm64EcRsp = Join-Path $arm64EcReproDir "link.rsp"

  $rspPaths = @{
    arm64   = $arm64Rsp
    arm64ec = $arm64EcRsp
  }

  [PSCustomObject]@{
    SourceRoot = $sourceRoot
    Config     = $Config
    Generator  = $Generator
    Targets    = $targets
    VsEnv      = $vsEnv
    BuildDirs  = $buildDirs
    RspPaths   = $rspPaths
  }
}

function Write-ContextSummary {
  param([PSCustomObject]$Context)

  Write-Host "Source    : $($Context.SourceRoot)"
  Write-Host "TargetDLL : $($Context.Targets.Dll)"
  Write-Host "OutDir    : $($Context.Targets.OutDir)"
  Write-Host "Config    : $($Context.Config)"
  Write-Host "Generator : $($Context.Generator)"
  Write-Host "VS Root   : $($Context.VsEnv.VsRoot)"
}

function Invoke-ConfigureStage {
  param(
    [PSCustomObject]$Context,
    [switch]$SkipConfigure,
    [switch]$SkipConfigureArm64,
    [switch]$SkipConfigureArm64EC
  )

  if ($SkipConfigure) {
    Write-Host "Configure : skipped"
    return
  }

  if ($SkipConfigureArm64) {
    Write-Host "Configure (ARM64) : skipped"
  } else {
    Configure-CMake -VsDevCmd $Context.VsEnv.VsDevCmd -Source $Context.SourceRoot -BuildDir $Context.BuildDirs.arm64 -Generator $Context.Generator -Arch "arm64" -Config $Context.Config -LinkRspPath $Context.RspPaths.arm64
  }

  if ($SkipConfigureArm64EC) {
    Write-Host "Configure (ARM64EC) : skipped"
  } else {
    $arm64EcReproDir = Split-Path $Context.RspPaths.arm64ec -Parent
    if (Test-Path $arm64EcReproDir) {
      Remove-Item -Path $arm64EcReproDir -Recurse -Force
    }
    Ensure-Directory $arm64EcReproDir
    Configure-CMake -VsDevCmd $Context.VsEnv.VsDevCmd -Source $Context.SourceRoot -BuildDir $Context.BuildDirs.arm64ec -Generator $Context.Generator -Arch "arm64ec" -Config $Context.Config -LinkRspPath $arm64EcReproDir -ReproMode "LinkRepro"
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
  } else {
    Build-CMake -VsDevCmd $Context.VsEnv.VsDevCmd -BuildDir $Context.BuildDirs.arm64 -Config $Context.Config -Target $Context.Targets.Target -Arch "arm64"
  }

  if ($SkipBuildArm64EC) {
    Write-Host "Build (ARM64EC) : skipped"
  } else {
    Build-CMake -VsDevCmd $Context.VsEnv.VsDevCmd -BuildDir $Context.BuildDirs.arm64ec -Config $Context.Config -Target $Context.Targets.Target -Arch "arm64ec"
  }
}

function Invoke-LinkStage {
  param(
    [PSCustomObject]$Context,
    [switch]$SkipLink,
    [string]$Def
  )

  if ($SkipLink) {
    Write-Host "Link      : skipped"
    return
  }

  Ensure-Arm64EcFullRsp -Context $Context | Out-Null
  $arm64EcData = Parse-LinkRsp -Path $Context.RspPaths.arm64ec
  $arm64Data = Parse-LinkRsp -Path $Context.RspPaths.arm64

  $defOverride = Resolve-DefinitionOption -Def $Def -SourceRoot $Context.SourceRoot

  $plan = Merge-LinkData -Arm64Ec $arm64EcData -Arm64 $arm64Data -DefOverride $defOverride

  foreach ($artifact in @($Context.Targets.Dll, $Context.Targets.Pdb, $Context.Targets.Lib)) {
    Remove-ExistingFile -Path $artifact
  }

  $linkArgs = @(
    "/nologo",
    "/dll",
    "/MACHINE:ARM64X",
    ('/OUT:"{0}"' -f $Context.Targets.Dll),
    ('/PDB:"{0}"' -f $Context.Targets.Pdb),
    ('/IMPLIB:"{0}"' -f $Context.Targets.Lib)
  )
  $cmdParts = New-Object System.Collections.Generic.List[string]
  foreach ($arg in $linkArgs) { $cmdParts.Add($arg) }
  # Feed ARM64EC response first so the tk/link driver treats it as primary, then append ARM64 inputs.
  $cmdParts.Add(('^@"{0}"' -f $Context.RspPaths.arm64ec))
  $cmdParts.Add(('^@"{0}"' -f $Context.RspPaths.arm64))
  $cmdParts.Add("/MACHINE:ARM64X")

  
  foreach ($extra in $plan.ExtraLibs) {
    $formatted = Format-LinkToken -Token $extra
    if ($formatted) { $cmdParts.Add($formatted) }
  }
  $linkCmd = "link.exe {0}" -f ($cmdParts -join ' ')
  Invoke-VsCommand -VsDevCmd $Context.VsEnv.VsDevCmd -CommandLine $linkCmd -Arch "amd64" -Tag "link-arm64x"

  Write-Host ""
  Write-Host ("Hybrid DLL : {0}" -f $Context.Targets.Dll) -ForegroundColor Green
  Write-Host ("PDB        : {0}" -f $Context.Targets.Pdb) -ForegroundColor Green
  Write-Host ("Import Lib : {0}" -f $Context.Targets.Lib) -ForegroundColor Green
  Write-Host ("Responses  : {0}; {1}" -f $Context.RspPaths.arm64ec, $Context.RspPaths.arm64) -ForegroundColor Green
  if ($plan.ExtraLibs -and $plan.ExtraLibs.Count -gt 0) {
    Write-Host ("Extra Libs : {0}" -f ($plan.ExtraLibs -join "; ")) -ForegroundColor Green
  }
}

function Invoke-Main {
  param(
    [string]$SourceDir,
    [string]$TargetDll,
    [string]$OutDir,
    [string]$Config,
    [string]$Generator,
    [string]$VsWhere,
    [switch]$SkipConfigure,
    [switch]$SkipConfigureArm64,
    [switch]$SkipConfigureArm64EC,
    [switch]$SkipBuild,
    [switch]$SkipBuildArm64,
    [switch]$SkipBuildArm64EC,
    [switch]$SkipProjectBuild,
    [switch]$SkipLink,
    [string]$Def
  )

  $context = New-BuildContext -SourceDir $SourceDir -TargetDll $TargetDll -OutDir $OutDir -Config $Config -Generator $Generator -VsWhere $VsWhere
  Write-ContextSummary -Context $context

  Invoke-ConfigureStage -Context $context -SkipConfigure:$SkipConfigure -SkipConfigureArm64:$SkipConfigureArm64 -SkipConfigureArm64EC:$SkipConfigureArm64EC

  $skipProjectBuildEffective = $SkipBuild -or $SkipProjectBuild
  Invoke-BuildStage -Context $context -SkipBuild:$skipProjectBuildEffective -SkipBuildArm64:$SkipBuildArm64 -SkipBuildArm64EC:$SkipBuildArm64EC

  Invoke-LinkStage -Context $context -SkipLink:$SkipLink -Def $Def
}

Invoke-Main `
  -SourceDir $SourceDir `
  -TargetDll $TargetDll `
  -OutDir $OutDir `
  -Config $Config `
  -Generator $Generator `
  -VsWhere $VsWhere `
  -SkipConfigure:$SkipConfigure `
  -SkipConfigureArm64:$SkipConfigureArm64 `
  -SkipConfigureArm64EC:$SkipConfigureArm64EC `
  -SkipBuild:$SkipBuild `
  -SkipBuildArm64:$SkipBuildArm64 `
  -SkipBuildArm64EC:$SkipBuildArm64EC `
  -SkipProjectBuild:$SkipProjectBuild `
  -SkipLink:$SkipLink `
  -Def $Def
