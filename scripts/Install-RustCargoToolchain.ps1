<#
.SYNOPSIS
  Install a pinned darbot Rust toolchain (e.g. darbot-1.100.0) from the
  darbotlm/rust_cargo release mirror and register it with rustup.

.DESCRIPTION
  Drop-in replacement for the internal 1ES `ms-prod-<ver>` toolchain from
  Mxc-Azure-Feed. Every artifact is SHA-256 verified against
  toolchain/<name>.json before it is unpacked. The toolchain is installed as
  a rustup *linked* toolchain named after the manifest (`darbot-1.100.0`), so
  `cargo +darbot-1.100.0` / `RUSTUP_TOOLCHAIN=darbot-1.100.0` select it.

.EXAMPLE
  ./Install-RustCargoToolchain.ps1 -Toolchain darbot-1.100.0 -AdditionalTargets aarch64-pc-windows-msvc
#>
[CmdletBinding()]
param(
    [string] $Toolchain = 'darbot-1.100.0',
    [string] $Repo = 'darbotlm/rust_cargo',
    [string] $HostTarget,
    [string[]] $AdditionalTargets = @(),
    [string] $InstallRoot = $(if ($env:RUST_CARGO_HOME) { $env:RUST_CARGO_HOME } else { Join-Path $HOME '.rust_cargo' }),
    [string] $ManifestPath,
    [switch] $SetDefault
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RustCargo.Common.ps1')

$manifest = Get-RustCargoManifest -Toolchain $Toolchain -Repo $Repo -ManifestPath $ManifestPath
if (-not $HostTarget) { $HostTarget = Get-RustCargoHostTarget }
$AdditionalTargets = @($AdditionalTargets | ForEach-Object { $_ -split '[,; ]' } | Where-Object { $_ -and $_ -ne $HostTarget } | Select-Object -Unique)

$dest = Join-Path $InstallRoot "toolchains/$Toolchain-$HostTarget"
$work = Join-Path $InstallRoot "downloads/$Toolchain"
New-Item -ItemType Directory -Force $dest, $work | Out-Null

$hostAsset = $manifest.host.$HostTarget
if (-not $hostAsset) { throw "Toolchain $Toolchain has no host package for $HostTarget. Available: $(($manifest.host.PSObject.Properties.Name) -join ', ')" }

$marker = Join-Path $dest '.rust_cargo-installed.json'
$installed = if (Test-Path $marker) { Get-Content $marker -Raw | ConvertFrom-Json } else { $null }

if (-not $installed -or $installed.sha256 -ne $hostAsset.sha256) {
    Write-Host "Installing $Toolchain ($($manifest.rustcVersion)) for $HostTarget"
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $dest | Out-Null
    $pkg = Get-RustCargoAsset -Repo $Repo -Tag $manifest.releaseTag -Asset $hostAsset -WorkDir $work
    Install-RustDistPackage -Package $pkg -Destination $dest -WorkDir $work -Exclude $manifest.excludeComponents
    @{ toolchain = $Toolchain; sha256 = $hostAsset.sha256; targets = @($HostTarget) } | ConvertTo-Json | Set-Content $marker
    $installed = Get-Content $marker -Raw | ConvertFrom-Json
}

foreach ($t in $AdditionalTargets) {
    if ($installed.targets -contains $t) { continue }
    $std = $manifest.std.$t
    if (-not $std) { throw "Toolchain $Toolchain has no rust-std package for $t. Available: $(($manifest.std.PSObject.Properties.Name) -join ', ')" }
    Write-Host "Adding rust-std for $t"
    $pkg = Get-RustCargoAsset -Repo $Repo -Tag $manifest.releaseTag -Asset $std -WorkDir $work
    Install-RustDistPackage -Package $pkg -Destination $dest -WorkDir $work
    $installed.targets = @($installed.targets) + $t
    $installed | ConvertTo-Json | Set-Content $marker
}

$rustc = Join-Path $dest ("bin/rustc" + $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { '.exe' } else { '' }))
$ver = & $rustc -V
if ($ver -notmatch [regex]::Escape($manifest.rustcCommit)) { throw "rustc reports '$ver', expected commit $($manifest.rustcCommit)" }

& rustup toolchain link $Toolchain $dest
if ($LASTEXITCODE) { throw "rustup toolchain link failed ($LASTEXITCODE)" }
if ($SetDefault) { & rustup default $Toolchain }

if ($env:TF_BUILD) {
    Write-Host "##vso[task.setvariable variable=RUSTUP_TOOLCHAIN]$Toolchain"
    Write-Host "##vso[task.prependpath]$(Join-Path $dest 'bin')"
} elseif ($env:GITHUB_ENV) {
    "RUSTUP_TOOLCHAIN=$Toolchain" | Add-Content $env:GITHUB_ENV
}
Write-Host "OK: $ver -> $Toolchain ($dest)"
