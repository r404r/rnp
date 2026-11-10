# Package an unsigned x64 Windows portable directory and smoke-test the zip.
# The shared library keeps the name rnp.dll from the CMake OUTPUT_NAME.
# Keyrings default to HOME\.rnp or USERPROFILE\.rnp; portable use passes --homedir.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('package', 'smoke')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Native tools write status to stderr. Do not turn that into a terminating error;
# callers check $LASTEXITCODE instead.
$PSNativeCommandUseErrorActionPreference = $false

$Workspace = $env:GITHUB_WORKSPACE
if (-not $Workspace) { $Workspace = (Get-Location).Path }
$StageName = 'rnp-windows-x64-portable'
$Stage = Join-Path $Workspace $StageName
$ZipPath = Join-Path $Workspace ($StageName + '.zip')
$Triplet = 'x64-windows'
$VcpkgRoot = 'C:\vcpkg'
$VcpkgInstalled = Join-Path $VcpkgRoot "installed\$Triplet"
$VcpkgBin = Join-Path $VcpkgInstalled 'bin'

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )
    & $File @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$File exited with code $LASTEXITCODE"
    }
}

function Get-VsInstallPath {
    $vswhere = 'C:\ProgramData\Chocolatey\bin\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw "vswhere not found at $vswhere"
    }
    $root = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
    if (-not $root) { throw 'Visual Studio installation path not found' }
    return $root.Trim()
}

function Get-Dumpbin {
    param([string]$VsRoot)
    $verFiles = @(Get-ChildItem (Join-Path $VsRoot 'VC\Auxiliary\Build') -Filter 'Microsoft.VCToolsVersion*.default.txt' -File)
    if ($verFiles.Count -lt 1) { throw "MSVC toolset version file not found under $VsRoot" }
    $verFile = $verFiles | Sort-Object Name -Descending | Select-Object -First 1
    $ver = (Get-Content $verFile.FullName -Raw).Trim()
    $dumpbin = Join-Path $VsRoot "VC\Tools\MSVC\$ver\bin\Hostx64\x64\dumpbin.exe"
    if (-not (Test-Path $dumpbin)) { throw "dumpbin not found at $dumpbin" }
    return $dumpbin
}

function Get-CrtDirectories {
    param([string]$VsRoot)
    $redist = Join-Path $VsRoot 'VC\Redist\MSVC'
    if (-not (Test-Path $redist)) { throw "MSVC redist directory not found: $redist" }
    # VS 2022 also has an empty-or-alias v143 directory next to the numbered
    # 14.x redist. Use a folder that actually contains x64 runtime files.
    $usable = @()
    foreach ($ver in (Get-ChildItem $redist -Directory)) {
        $x64 = Join-Path $ver.FullName 'x64'
        if (-not (Test-Path $x64)) { continue }
        $sub = @(Get-ChildItem $x64 -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $dlls = @(Get-ChildItem $x64 -Filter '*.dll' -File -ErrorAction SilentlyContinue)
        if ($sub.Count -gt 0) {
            $usable += [pscustomobject]@{ Name = $ver.Name; VersionDir = $ver.FullName; Dirs = $sub }
        } elseif ($dlls.Count -gt 0) {
            $usable += [pscustomobject]@{ Name = $ver.Name; VersionDir = $ver.FullName; Dirs = @($x64) }
        }
    }
    if ($usable.Count -lt 1) {
        Write-Host "Redist tree under ${redist}:"
        Get-ChildItem $redist -Recurse -Depth 2 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.FullName }
        throw "No MSVC x64 redistributable folders under $redist"
    }
    $best = $usable | Sort-Object Name -Descending | Select-Object -First 1
    Write-Host "Using MSVC redist $($best.VersionDir)"
    return @{
        VersionDir = $best.VersionDir
        Dirs       = $best.Dirs
    }
}

function Get-PeImports {
    param(
        [string]$Path,
        [string]$Dumpbin
    )
    $dumpbinDir = Split-Path $Dumpbin -Parent
    $saved = $env:PATH
    $env:PATH = "$dumpbinDir;$saved"
    try {
        $lines = & $Dumpbin /nologo /dependents $Path
        if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $Path" }
    } finally {
        $env:PATH = $saved
    }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\s+([A-Za-z0-9_.+-]+\.dll)\s*$') {
            $names.Add($Matches[1])
        }
    }
    return $names
}

function Find-BuildOutput {
    param([string]$Name)
    $build = Join-Path $Workspace 'build'
    $hits = @(Get-ChildItem -Path $build -Recurse -Filter $Name -File | Where-Object {
            $_.FullName -notmatch '\\CMakeFiles\\' -and $_.FullName -notmatch '\\tests\\'
        })
    if ($hits.Count -lt 1) {
        Write-Host "Build tree under ${build}:"
        Get-ChildItem $build -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Select-Object -First 80 |
            ForEach-Object { Write-Host $_.FullName }
        throw "Build output not found: $Name"
    }
    # Prefer the link output over copies made beside test executables.
    $ranked = @($hits | Sort-Object { $_.FullName.Length }, { $_.FullName })
    $libRelease = @($ranked | Where-Object { $_.FullName -match '\\src\\lib\\Release\\' })
    if ($libRelease.Count -ge 1) { return $libRelease[0].FullName }
    $release = @($ranked | Where-Object { $_.FullName -match '\\Release\\' })
    if ($release.Count -ge 1) { return $release[0].FullName }
    $cli = @($ranked | Where-Object { $_.Directory.Name -in @('rnp', 'rnpkeys', 'examples') })
    if ($cli.Count -ge 1) { return $cli[0].FullName }
    return $ranked[0].FullName
}

function Resolve-Dependency {
    param(
        [string]$Name,
        [string[]]$SearchDirs
    )
    # API-set contracts are resolved by the loader on Windows 10 and later.
    # They are not files we can ship next to the executable.
    if ($Name -match '^(?i)(api-ms-win-|ext-ms-)') {
        return $null
    }
    foreach ($dir in $SearchDirs) {
        if (-not $dir) { continue }
        $candidate = Join-Path $dir $Name
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    foreach ($extra in @('System32', 'System32\downlevel')) {
        $system = Join-Path (Join-Path $env:SystemRoot $extra) $Name
        if (Test-Path -LiteralPath $system) { return $null }
    }
    Write-Host "Could not resolve ${Name}. Searched:"
    foreach ($dir in $SearchDirs) { Write-Host "  $dir" }
    throw "Unresolved non-system dependency: $Name"
}

function Copy-VcpkgLicenseForDll {
    param(
        [string]$DllName,
        [string]$LicenseDir,
        [hashtable]$CopiedPorts
    )
    $info = Join-Path $VcpkgRoot 'installed\vcpkg\info'
    if (-not (Test-Path $info)) { return $false }
    $needle = "bin/$DllName"
    $needleWin = "bin\$DllName"
    foreach ($list in Get-ChildItem $info -Filter "*_${Triplet}.list" -File) {
        $lines = @(Get-Content -LiteralPath $list.FullName)
        $owns = $false
        foreach ($line in $lines) {
            $norm = $line.Replace('\', '/')
            if ($norm -notmatch '/debug/bin/' -and (
                    $norm.EndsWith($needle, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $line.EndsWith($needleWin, [System.StringComparison]::OrdinalIgnoreCase))) {
                $owns = $true
                break
            }
        }
        if (-not $owns) { continue }
        foreach ($line in $lines) {
            $norm = $line.Replace('\', '/')
            if ($norm -match '(^|/)share/([^/]+)/copyright$') {
                $port = $Matches[2]
                if ($CopiedPorts.ContainsKey($port)) { return $true }
                $full = Join-Path (Join-Path $VcpkgRoot 'installed') ($line.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $full)) {
                    $full = Join-Path $VcpkgInstalled ($line.Replace('/', '\'))
                }
                if (-not (Test-Path -LiteralPath $full)) {
                    throw "Copyright file listed but missing for ${port}: $line"
                }
                Copy-Item -LiteralPath $full -Destination (Join-Path $LicenseDir "vcpkg-$port.txt")
                $CopiedPorts[$port] = $true
                Write-Host "License for $DllName -> vcpkg-$port.txt"
                return $true
            }
        }
        throw "vcpkg list owns $DllName but has no copyright entry: $($list.Name)"
    }
    return $false
}

function Copy-KnownPortLicense {
    param(
        [string]$Port,
        [string]$LicenseDir,
        [hashtable]$CopiedPorts
    )
    if ($CopiedPorts.ContainsKey($Port)) { return }
    # A DLL may be owned by a more specific port than the name we installed.
    # getopt.dll is shipped by getopt-win32, which already satisfies getopt.
    foreach ($have in @($CopiedPorts.Keys)) {
        if ($have -like "$Port*" -or $Port -like "$have*") { return }
    }
    $share = Join-Path $VcpkgInstalled 'share'
    $portDir = Join-Path $share $Port
    if (Test-Path -LiteralPath $portDir) {
        $lic = @(Get-ChildItem $portDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(?i)(copyright|license|copying)' } |
                Select-Object -First 1)
        if ($lic.Count -ge 1) {
            Copy-Item -LiteralPath $lic[0].FullName -Destination (Join-Path $LicenseDir "vcpkg-$Port.txt")
            $CopiedPorts[$Port] = $true
            Write-Host "License for port $Port ($($lic[0].Name))"
            return
        }
        Write-Host "Files in ${portDir}:"
        Get-ChildItem $portDir -Force | ForEach-Object { Write-Host "  $($_.Name)" }
    }
    Write-Host "Share directories:"
    if (Test-Path $share) {
        Get-ChildItem $share -Directory | ForEach-Object { Write-Host $_.Name }
    }
    throw "Missing vcpkg copyright for port $Port"
}

function Write-NlohmannLicense {
    param([string]$Destination)
    $text = @"
JSON for Modern C++ (nlohmann/json)
SPDX-FileCopyrightText: 2013-2023 Niels Lohmann <https://nlohmann.me>
SPDX-License-Identifier: MIT

The vendored header records the MIT license via SPDX and does not ship a
separate LICENSE file. The MIT terms are:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"@
    [System.IO.File]::WriteAllText($Destination, $text.Replace("`n", "`r`n"))
}

function Write-Readme {
    param(
        [string]$Destination,
        [string]$VersionText
    )
    $sha = $env:GITHUB_SHA
    if (-not $sha) { $sha = 'unknown' }
    $text = @"
RNP portable build for 64-bit Windows
======================================

Unsigned, installer-free build of RNP for x64 Windows.
There is no Authenticode signature and no MSI. Windows SmartScreen may warn
when rnp.exe or rnpkeys.exe is started.

Source revision: $sha

$VersionText

Contents
--------
rnp.exe        OpenPGP file tool
rnpkeys.exe    key management tool
rnp.dll        RNP shared library (Windows file name of librnp)
*.dll          runtime dependencies; leave them next to the executables
licenses\      license texts for RNP and each bundled dependency
README.txt     this file

Keep every DLL in the same directory as the executables.

Key storage
-----------
Without --homedir, RNP stores keyrings in %HOME%\.rnp when HOME is set.
Otherwise it uses %USERPROFILE%\.rnp, or the Windows profile folder when
neither variable is set. That directory is shared by every RNP build that
uses the default location.

Portable use needs an explicit directory, and the directory must already
exist. Pass the same --homedir to rnp.exe and rnpkeys.exe:

  rnpkeys.exe --homedir C:\path\to\keys --generate-key --userid "Name <name@example.com>"
  rnp.exe --homedir C:\path\to\keys --encrypt --recipient "name@example.com" --armor message.txt
  rnp.exe --homedir C:\path\to\keys --decrypt message.txt.asc

This build links Botan, zlib, and bzip2 dynamically, and it links the
Visual C++ runtime dynamically. Those DLLs are included beside the
executables. Licenses are under licenses\.
"@
    [System.IO.File]::WriteAllText($Destination, $text.Replace("`n", "`r`n"))
}

function Package-Portable {
    if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
    $licenseDir = Join-Path $Stage 'licenses'
    New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null

    $rnpExe = Find-BuildOutput 'rnp.exe'
    $rnpKeys = Find-BuildOutput 'rnpkeys.exe'
    $rnpDll = Find-BuildOutput 'rnp.dll'
    Write-Host "Packaging rnp.exe from $rnpExe"
    Write-Host "Packaging rnpkeys.exe from $rnpKeys"
    Write-Host "Packaging rnp.dll from $rnpDll"
    if (-not (Test-Path -LiteralPath $VcpkgBin)) {
        throw "vcpkg bin directory not found: $VcpkgBin"
    }
    Write-Host "vcpkg bin ${VcpkgBin}:"
    Get-ChildItem $VcpkgBin -Filter '*.dll' -File | ForEach-Object { Write-Host "  $($_.Name)" }
    Copy-Item -LiteralPath $rnpExe -Destination (Join-Path $Stage 'rnp.exe')
    Copy-Item -LiteralPath $rnpKeys -Destination (Join-Path $Stage 'rnpkeys.exe')
    Copy-Item -LiteralPath $rnpDll -Destination (Join-Path $Stage 'rnp.dll')

    $vs = Get-VsInstallPath
    $dumpbin = Get-Dumpbin $vs
    $crt = Get-CrtDirectories $vs
    $search = @($Stage) + @($VcpkgBin) + $crt.Dirs

    $rnpImports = @(Get-PeImports (Join-Path $Stage 'rnp.exe') $dumpbin)
    $keysImports = @(Get-PeImports (Join-Path $Stage 'rnpkeys.exe') $dumpbin)
    Write-Host "rnp.exe imports: $($rnpImports -join ', ')"
    Write-Host "rnpkeys.exe imports: $($keysImports -join ', ')"
    if (@($rnpImports | ForEach-Object { $_.ToLower() }) -notcontains 'rnp.dll') {
        throw "rnp.exe does not import rnp.dll: $($rnpImports -join ', ')"
    }
    if (@($keysImports | ForEach-Object { $_.ToLower() }) -notcontains 'rnp.dll') {
        throw "rnpkeys.exe does not import rnp.dll: $($keysImports -join ', ')"
    }

    $pending = New-Object System.Collections.Generic.Queue[string]
    $seen = @{}
    foreach ($exe in @('rnp.exe', 'rnpkeys.exe', 'rnp.dll')) {
        $pending.Enqueue((Join-Path $Stage $exe))
        $seen[$exe.ToLower()] = $true
    }
    $bundledVc = $false
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        $imports = @(Get-PeImports $current $dumpbin)
        foreach ($name in $imports) {
            $key = $name.ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $resolved = Resolve-Dependency $name $search
            if (-not $resolved) {
                Write-Host "OS component, not bundled: $name"
                continue
            }
            $dest = Join-Path $Stage $name
            if (-not (Test-Path -LiteralPath $dest)) {
                Copy-Item -LiteralPath $resolved -Destination $dest
                Write-Host "Bundled $name from $resolved"
            }
            if ($resolved -match '\\VC\\Redist\\' -or $key -match '^(vcruntime|msvcp|concrt|vcomp|vccorlib)') {
                $bundledVc = $true
            }
            $pending.Enqueue($dest)
        }
    }

    $copiedPorts = @{}
    foreach ($dll in Get-ChildItem $Stage -Filter '*.dll' -File) {
        if ($dll.Name -match '^(rnp\.dll|vcruntime|msvcp|concrt|vcomp|vccorlib)') { continue }
        $found = Copy-VcpkgLicenseForDll $dll.Name $licenseDir $copiedPorts
        if (-not $found) {
            throw "No vcpkg license mapped for bundled DLL $($dll.Name)"
        }
    }
    foreach ($port in @('botan', 'bzip2', 'zlib', 'getopt', 'dirent')) {
        Copy-KnownPortLicense $port $licenseDir $copiedPorts
    }

    Copy-Item -LiteralPath (Join-Path $Workspace 'LICENSE.md') -Destination (Join-Path $licenseDir 'RNP-LICENSE.md')
    Copy-Item -LiteralPath (Join-Path $Workspace 'LICENSE-OCB.md') -Destination (Join-Path $licenseDir 'RNP-LICENSE-OCB.md')
    $sexppLicenses = @(Get-ChildItem (Join-Path $Workspace 'src\libsexpp') -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|COPYRIGHT)' })
    if ($sexppLicenses.Count -lt 1) { throw 'sexpp license file not found in src/libsexpp' }
    Copy-Item -LiteralPath $sexppLicenses[0].FullName -Destination (Join-Path $licenseDir ("sexpp-" + $sexppLicenses[0].Name))
    Write-NlohmannLicense (Join-Path $licenseDir 'nlohmann-json-MIT.txt')

    if ($bundledVc) {
        # -Include only applies when the path itself contains a wildcard, so a
        # -Recurse -Include search silently returns nothing on these images.
        $vcLicense = @(Get-ChildItem $crt.VersionDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(?i)license\.(txt|rtf)$' })
        if ($vcLicense.Count -lt 1) {
            $licenseRoot = Join-Path $vs 'Licenses'
            if (Test-Path $licenseRoot) {
                $vcLicense = @(Get-ChildItem $licenseRoot -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^(?i)license\.(txt|rtf|htm|html)$' } |
                        Select-Object -First 1)
            }
        }
        $notice = Join-Path $licenseDir 'msvc-runtime-license.txt'
        if ($vcLicense.Count -ge 1) {
            Copy-Item -LiteralPath $vcLicense[0].FullName -Destination $notice
            Write-Host "MSVC runtime license: $($vcLicense[0].FullName)"
        } else {
            # The numbered CRT folder on the runner contains the DLLs and no
            # separate license text. Record where the binaries came from.
            $crtDir = @($crt.Dirs | Where-Object { $_ -match 'Microsoft\.VC143\.CRT' } | Select-Object -First 1)
            if (-not $crtDir) { $crtDir = $crt.VersionDir }
            $note = @"
Microsoft Visual C++ runtime (VC143)

The Visual C++ runtime DLLs in this archive were copied from:
$crtDir

That directory does not include a separate license file. These binaries are
the Visual C++ Redistributable runtime. Their redistribution is covered by
the Visual Studio license terms:
https://visualstudio.microsoft.com/license-terms/
https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution
"@
            [System.IO.File]::WriteAllText($notice, $note.Replace("`n", "`r`n"))
            Write-Host "Wrote MSVC runtime license notice (no license file beside the CRT DLLs)"
        }
    }

    $stageDlls = @(Get-ChildItem $Stage -Filter '*.dll' -File | ForEach-Object { $_.Name.ToLower() })
    foreach ($name in @(Get-PeImports (Join-Path $Stage 'rnp.dll') $dumpbin)) {
        if ($name -match '^(?i)(api-ms-win-|ext-ms-)') { continue }
        $inSystem = $false
        foreach ($extra in @('System32', 'System32\downlevel')) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path $env:SystemRoot $extra) $name)) { $inSystem = $true }
        }
        if ($inSystem) { continue }
        if ($stageDlls -notcontains $name.ToLower()) {
            throw "rnp.dll import '$name' was not copied into the package. Staged DLLs: $($stageDlls -join ', ')"
        }
    }

    $savedPath = $env:PATH
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    try {
        $version = & (Join-Path $Stage 'rnp.exe') --version 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $version) {
            throw "rnp.exe --version failed during packaging (exit $LASTEXITCODE): $version"
        }
    } finally {
        $env:PATH = $savedPath
    }
    $versionText = ($version | Select-Object -First 6) -join "`n"
    Write-Readme (Join-Path $Stage 'README.txt') $versionText

    $required = @('rnp.exe', 'rnpkeys.exe', 'rnp.dll', 'README.txt')
    foreach ($name in $required) {
        if (-not (Test-Path (Join-Path $Stage $name))) { throw "Package is missing $name" }
    }
    $dllCount = @(Get-ChildItem $Stage -Filter '*.dll' -File).Count
    if ($dllCount -lt 2) { throw "Expected dependency DLLs next to rnp.dll, found $dllCount DLL(s)" }
    $licenseCount = @(Get-ChildItem $licenseDir -File).Count
    if ($licenseCount -lt 4) { throw "Expected license files, found $licenseCount" }

    Invoke-Native 'tar.exe' @('-a', '-cf', $ZipPath, '-C', $Workspace, $StageName)
    Write-Host '==== portable tree ===='
    Get-ChildItem $Stage -Recurse -File | ForEach-Object {
        '{0,12}  {1}' -f $_.Length, $_.FullName.Substring($Stage.Length + 1)
    }
    $zipItem = Get-Item $ZipPath
    Write-Host "ZIP_SIZE_BYTES=$($zipItem.Length)"
    Write-Host '==== zip listing ===='
    & tar.exe -tf $ZipPath
    if ($LASTEXITCODE -ne 0) { throw 'tar listing failed' }

    if ($env:GITHUB_STEP_SUMMARY) {
        $lines = @(
            '### Windows portable zip',
            '',
            ('- Zip bytes: {0}' -f $zipItem.Length),
            ('- DLLs: {0}' -f $dllCount),
            ('- License files: {0}' -f $licenseCount),
            '',
            ($version | Select-Object -First 4 | ForEach-Object { '    ' + $_ })
        )
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n")
    }
}

function Smoke-Portable {
    if (-not $env:RUNNER_TEMP) { throw 'RUNNER_TEMP is not set' }
    if (-not (Test-Path $ZipPath)) { throw "Zip not found: $ZipPath" }
    $dest = Join-Path $env:RUNNER_TEMP 'rnp-portable-smoke'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Invoke-Native 'tar.exe' @('-xf', $ZipPath, '-C', $dest)
    Write-Host 'Extracted zip:'
    Get-ChildItem $dest -Recurse -File | ForEach-Object { Write-Host $_.FullName }
    $root = Join-Path $dest $StageName
    if (-not (Test-Path (Join-Path $root 'rnp.exe'))) {
        throw "Extracted zip has no $StageName\rnp.exe"
    }
    $home = Join-Path $env:RUNNER_TEMP 'rnp-portable-homedir'
    if (Test-Path $home) { Remove-Item -Recurse -Force $home }
    New-Item -ItemType Directory -Force -Path $home | Out-Null
    $plain = Join-Path $env:RUNNER_TEMP 'rnp-portable-plain.txt'
    $enc = Join-Path $env:RUNNER_TEMP 'rnp-portable-plain.txt.asc'
    $dec = Join-Path $env:RUNNER_TEMP 'rnp-portable-plain.dec'
    $payload = [Text.Encoding]::ASCII.GetBytes('portable-smoke-ok')
    [System.IO.File]::WriteAllBytes($plain, $payload)

    if (-not (Test-Path -LiteralPath $home)) { throw "homedir was not created: $home" }
    $savedPath = $env:PATH
    # Application directory is searched before PATH, so dependency DLLs must
    # sit next to the executables. Leave only the OS directories on PATH.
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    Set-Location $env:RUNNER_TEMP
    try {
        $rnp = Join-Path $root 'rnp.exe'
        $rnpkeys = Join-Path $root 'rnpkeys.exe'
        Write-Host "Smoke PATH=$($env:PATH)"
        Write-Host "Smoke homedir=$home"
        Write-Host '== rnp.exe --version =='
        $verOut = & $rnp --version 2>&1
        $verOut | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0 -or -not $verOut) { throw "rnp.exe --version failed ($LASTEXITCODE)" }
        Write-Host '== rnpkeys.exe --version =='
        $keysVer = & $rnpkeys --version 2>&1
        $keysVer | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0 -or -not $keysVer) { throw "rnpkeys.exe --version failed ($LASTEXITCODE)" }

        Write-Host '== rnpkeys generate =='
        $genOut = & $rnpkeys --generate-key --homedir $home --userid 'Portable Smoke <smoke@example.invalid>' --password 'smoke-test' --numbits 2048 --s2k-iterations 50000 --notty 2>&1
        $genOut | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "rnpkeys --generate-key failed ($LASTEXITCODE)" }
        if (-not (Test-Path (Join-Path $home 'pubring.gpg'))) { throw 'generate did not write pubring.gpg in --homedir' }
        if (-not (Test-Path (Join-Path $home 'secring.gpg'))) { throw 'generate did not write secring.gpg in --homedir' }

        Write-Host '== rnp encrypt =='
        $encOut = & $rnp --homedir $home --encrypt --recipient 'smoke@example.invalid' --armor --overwrite --output $enc $plain 2>&1
        $encOut | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "rnp --encrypt failed ($LASTEXITCODE)" }
        Write-Host '== rnp decrypt =='
        $decOut = & $rnp --homedir $home --decrypt --password 'smoke-test' --overwrite --output $dec $enc 2>&1
        $decOut | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "rnp --decrypt failed ($LASTEXITCODE)" }
        $got = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($dec))
        $want = [Convert]::ToBase64String($payload)
        if ($got -ne $want) {
            throw "decrypted bytes do not match plaintext"
        }
        Write-Host 'SMOKE_OK'
    } finally {
        $env:PATH = $savedPath
    }
}

switch ($Mode) {
    'package' { Package-Portable }
    'smoke' { Smoke-Portable }
}
