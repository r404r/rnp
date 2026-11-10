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
    if ($hits.Count -lt 1) { throw "Build output not found: $Name" }
    $preferred = @($hits | Where-Object { $_.FullName -match '\\Release\\' -or $_.Directory.Name -in @('rnp', 'rnpkeys') })
    if ($preferred.Count -ge 1) { return $preferred[0].FullName }
    return $hits[0].FullName
}

function Resolve-Dependency {
    param(
        [string]$Name,
        [string[]]$SearchDirs
    )
    foreach ($dir in $SearchDirs) {
        $candidate = Join-Path $dir $Name
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    $system = Join-Path $env:SystemRoot "System32\$Name"
    if (Test-Path -LiteralPath $system) { return $null }
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
            if ($norm -notmatch '/debug/bin/' -and ($norm.EndsWith($needle) -or $line.EndsWith($needleWin))) {
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
    $candidates = @(
        (Join-Path $VcpkgInstalled "share\$Port\copyright"),
        (Join-Path $VcpkgRoot "installed\$Triplet\share\$Port\copyright")
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $LicenseDir "vcpkg-$Port.txt")
            $CopiedPorts[$Port] = $true
            Write-Host "License for port $Port"
            return
        }
    }
    $share = Join-Path $VcpkgInstalled 'share'
    $found = @(Get-ChildItem $share -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$Port*" })
    if ($found.Count -eq 1) {
        $path = Join-Path $found[0].FullName 'copyright'
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $LicenseDir "vcpkg-$($found[0].Name).txt")
            $CopiedPorts[$found[0].Name] = $true
            Write-Host "License for port $($found[0].Name)"
            return
        }
    }
    Write-Host "Share directories:"
    Get-ChildItem $share -Directory | ForEach-Object { Write-Host $_.Name }
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
        $vcLicense = @(Get-ChildItem $crt.VersionDir -Recurse -File -Include 'license.txt', 'License.txt', 'LICENSE.txt' -ErrorAction SilentlyContinue)
        if ($vcLicense.Count -lt 1) {
            $vcLicense = @(Get-ChildItem (Join-Path $vs 'VC\Redist') -Recurse -File -Include 'license.txt', 'License.txt' -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if ($vcLicense.Count -lt 1) {
            throw "Visual C++ runtime DLLs were bundled but no redist license file was found under $($crt.VersionDir)"
        }
        Copy-Item -LiteralPath $vcLicense[0].FullName -Destination (Join-Path $licenseDir 'msvc-runtime-license.txt')
    }

    $savedPath = $env:PATH
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    try {
        $version = & (Join-Path $Stage 'rnp.exe') --version
        if ($LASTEXITCODE -ne 0) { throw "rnp.exe --version failed during packaging ($LASTEXITCODE)" }
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
    if (-not (Test-Path $ZipPath)) { throw "Zip not found: $ZipPath" }
    $dest = Join-Path $env:RUNNER_TEMP 'rnp-portable-smoke'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Invoke-Native 'tar.exe' @('-xf', $ZipPath, '-C', $dest)
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

    $savedPath = $env:PATH
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    Set-Location $env:RUNNER_TEMP
    try {
        $rnp = Join-Path $root 'rnp.exe'
        $rnpkeys = Join-Path $root 'rnpkeys.exe'
        Write-Host '== rnp.exe --version =='
        & $rnp --version
        if ($LASTEXITCODE -ne 0) { throw "rnp.exe --version failed ($LASTEXITCODE)" }
        Write-Host '== rnpkeys.exe --version =='
        & $rnpkeys --version
        if ($LASTEXITCODE -ne 0) { throw "rnpkeys.exe --version failed ($LASTEXITCODE)" }

        Write-Host '== rnpkeys generate =='
        & $rnpkeys --generate-key --homedir $home --userid 'Portable Smoke <smoke@example.invalid>' --password 'smoke-test' --numbits 2048 --s2k-iterations 50000 --notty
        if ($LASTEXITCODE -ne 0) { throw "rnpkeys --generate-key failed ($LASTEXITCODE)" }
        if (-not (Test-Path (Join-Path $home 'pubring.gpg'))) { throw 'generate did not write pubring.gpg in --homedir' }
        if (-not (Test-Path (Join-Path $home 'secring.gpg'))) { throw 'generate did not write secring.gpg in --homedir' }

        Write-Host '== rnp encrypt =='
        & $rnp --homedir $home --encrypt --recipient 'smoke@example.invalid' --armor --overwrite --output $enc $plain
        if ($LASTEXITCODE -ne 0) { throw "rnp --encrypt failed ($LASTEXITCODE)" }
        Write-Host '== rnp decrypt =='
        & $rnp --homedir $home --decrypt --password 'smoke-test' --overwrite --output $dec $enc
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
