# Installs Neovim on Windows remote hosts (counterpart of neovim_install.sh)
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Dir,
    [Parameter(Mandatory = $true)][ValidateSet('binary', 'source', 'system')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Arch,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Test-Nvim([string]$Path) {
    try { return [bool](& $Path -v 2>$null | Select-Object -First 1) } catch { return $false }
}

if ($Method -eq 'source') {
    Write-Error 'Building Neovim from source is not supported on Windows. Use a binary release or system Neovim.'
}

if ($Method -eq 'system') {
    if ($Version -ne 'system') { Write-Error 'Only accepted Neovim version for system Neovim is: system' }
    if (-not (Get-Command nvim -ErrorAction SilentlyContinue)) { Write-Error 'Did not find Neovim on the path' }
    Write-Output 'Neovim already on PATH. Skipping installation...'
    exit 0
}

$versionDir = Join-Path (Join-Path $Dir 'nvim-downloads') $Version
$nvimBinary = Join-Path $versionDir 'bin\nvim.exe'

if (-not $Force -and (Test-Path $nvimBinary) -and (Test-Nvim $nvimBinary)) {
    Write-Output "Neovim $Version is already installed. Skipping installation."
    Write-Output "Neovim $Version can be accessed at $nvimBinary"
    exit 0
}
if (Test-Path $nvimBinary) { Write-Warning 'Neovim installation is corrupted. Would re-install...' }

$assetName = if ($Arch -eq 'arm64') { 'nvim-win-arm64.zip' } else { 'nvim-win64.zip' }
$url = "https://github.com/neovim/neovim/releases/download/$Version/$assetName"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("remote-nvim-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    $zipPath = Join-Path $tempDir $assetName
    Write-Output "Downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zipPath

    # Checksums are only published through the release API for recent versions; verify when available
    try {
        $release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/neovim/neovim/releases/tags/$Version"
        $digest = ($release.assets | Where-Object { $_.name -eq $assetName }).digest
        if ($digest) {
            $expected = $digest -replace '^sha256:', ''
            $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash
            if ($actual -ine $expected) { Write-Error "Checksum mismatch for $assetName" }
            Write-Output 'Checksum verified'
        } else {
            Write-Output 'No checksum available for this release. Skipping verification'
        }
    } catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        Write-Output 'Could not fetch release checksum. Skipping verification'
    }

    Write-Output 'Extracting Neovim binary...'
    $extractDir = Join-Path $tempDir 'extract'
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $inner = Get-ChildItem $extractDir -Directory | Select-Object -First 1

    if (Test-Path $versionDir) { Remove-Item -Recurse -Force $versionDir }
    New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
    Move-Item -Path (Join-Path $inner.FullName '*') -Destination $versionDir -Force
} finally {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}

if (-not (Test-Nvim $nvimBinary)) { Write-Error "Installed Neovim at $nvimBinary does not run" }
Write-Output "Neovim $Version can be accessed at $nvimBinary"
