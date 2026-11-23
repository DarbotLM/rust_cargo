<#
.SYNOPSIS
  Point cargo at the darbotlm/rust_cargo vendored crate mirror (replacement
  for the internal Mxc-Azure-Feed cargo registry).

.DESCRIPTION
  Downloads the crate bundle whose name matches the SHA-256 of the project's
  Cargo.lock (crates-<lockhash16>.tar.gz) from the `crates` release, verifies
  it, unpacks it, and appends a `[source.crates-io] replace-with` block to the
  given cargo config. Builds then resolve every crates.io dependency from the
  mirror; pass --locked/--offline to guarantee nothing else is fetched.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $LockFile,
    [Parameter(Mandatory)] [string] $ConfigFile,
    [string] $Repo = 'darbotlm/rust_cargo',
    [string] $Tag = 'crates',
    [string] $InstallRoot = $(if ($env:RUST_CARGO_HOME) { $env:RUST_CARGO_HOME } else { Join-Path $HOME '.rust_cargo' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RustCargo.Common.ps1')

$lockHash = (Get-FileHash $LockFile -Algorithm SHA256).Hash.ToLower().Substring(0, 16)
$name = "crates-$lockHash.tar.gz"
$work = Join-Path $InstallRoot 'downloads/crates'
$vendor = Join-Path $InstallRoot "vendor/$lockHash"
New-Item -ItemType Directory -Force $work | Out-Null

if (-not (Test-Path (Join-Path $vendor '.complete'))) {
    $rel = Join-Path $work "release-$Tag.json"
    Invoke-RustCargoDownload "https://api.github.com/repos/$Repo/releases/tags/$Tag" $rel
    $assets = (Get-Content $rel -Raw | ConvertFrom-Json).assets
    $a = $assets | Where-Object name -eq $name
    $s = $assets | Where-Object name -eq "$name.sha256"
    if (-not $a -or -not $s) { throw "No crate bundle for Cargo.lock $lockHash in $Repo@$Tag. Publish one with Publish-RustCargoCrates.ps1." }
    $pkg = Join-Path $work $name; $sum = "$pkg.sha256"
    Invoke-RustCargoDownload $s.url $sum -Binary
    Invoke-RustCargoDownload $a.url $pkg -Binary
    $want = ((Get-Content $sum -Raw).Trim() -split '\s+')[0].ToUpper()
    $got = (Get-FileHash $pkg -Algorithm SHA256).Hash
    if ($got -ne $want) { throw "SHA-256 mismatch for ${name}: got $got, expected $want" }
    Remove-Item $vendor -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $vendor | Out-Null
    & tar -xzf $pkg -C $vendor
    if ($LASTEXITCODE) { throw "tar failed extracting $name" }
    New-Item (Join-Path $vendor '.complete') -ItemType File | Out-Null
}

$dir = (Resolve-Path $vendor).Path -replace '\\', '/'
New-Item -ItemType Directory -Force (Split-Path $ConfigFile) | Out-Null
Add-Content -Path $ConfigFile -Value @"

# --- darbotlm/rust_cargo crate mirror (Cargo.lock $lockHash) ---
[source.crates-io]
replace-with = "rust-cargo"

[source.rust-cargo]
directory = "$dir"
"@
Write-Host "OK: crates-io -> $dir"
if ($env:TF_BUILD) { Write-Host "##vso[task.setvariable variable=CARGO_NET_OFFLINE]true" }
