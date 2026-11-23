<#
.SYNOPSIS
  Vendor every crates.io dependency of a Cargo workspace and publish it to the
  darbotlm/rust_cargo `crates` release, keyed by the Cargo.lock hash.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceDir,
    [string] $Repo = 'darbotlm/rust_cargo',
    [string] $Tag = 'crates',
    [string] $Toolchain,
    [string] $WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'rust_cargo-crates'),
    [switch] $SkipUpload
)
$ErrorActionPreference = 'Stop'
$lock = Join-Path $WorkspaceDir 'Cargo.lock'
$lockHash = (Get-FileHash $lock -Algorithm SHA256).Hash.ToLower().Substring(0, 16)
$vendor = Join-Path $WorkDir "vendor-$lockHash"
$name = "crates-$lockHash.tar.gz"
$pkg = Join-Path $WorkDir $name
New-Item -ItemType Directory -Force $WorkDir | Out-Null
Remove-Item $vendor -Recurse -Force -ErrorAction SilentlyContinue

Push-Location $WorkspaceDir
try {
    # cmd /c: cargo writes progress to stderr, which Windows PowerShell 5.1
    # turns into terminating errors under ErrorActionPreference=Stop.
    $tc = if ($Toolchain) { "+$Toolchain " } else { '' }
    $log = Join-Path $WorkDir 'vendor.log'
    cmd /c "cargo ${tc}vendor --locked --versioned-dirs `"$vendor`" > `"$log`" 2>&1"
    if ($LASTEXITCODE) { Get-Content $log -Tail 20 | Write-Host; throw "cargo vendor failed ($LASTEXITCODE)" }
} finally { Pop-Location }

& tar -czf $pkg -C $vendor .
if ($LASTEXITCODE) { throw 'tar failed' }
$sha = (Get-FileHash $pkg -Algorithm SHA256).Hash.ToLower()
"$sha  $name" | Set-Content "$pkg.sha256" -NoNewline -Encoding ascii
$count = (Get-ChildItem $vendor -Directory).Count
Write-Host "$name : $count crates, $([math]::Round((Get-Item $pkg).Length / 1MB)) MB, sha256 $sha"

$index = Join-Path $PSScriptRoot '../crates/index.json'
$entries = if (Test-Path $index) { @(Get-Content $index -Raw | ConvertFrom-Json) } else { @() }
$entries = @($entries | Where-Object lockHash -ne $lockHash) + [pscustomobject]@{
    lockHash = $lockHash; asset = $name; sha256 = $sha; crates = $count
    workspace = (Split-Path $WorkspaceDir -Leaf); created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
New-Item -ItemType Directory -Force (Split-Path $index) | Out-Null
ConvertTo-Json @($entries) -Depth 4 | Set-Content $index -Encoding utf8

if (-not $SkipUpload) {
    cmd /c "gh release view $Tag -R $Repo >nul 2>&1"
    if ($LASTEXITCODE) {
        & gh release create $Tag -R $Repo --title 'Vendored crates' --notes 'crates.io mirror bundles keyed by Cargo.lock hash. Consume with scripts/Use-RustCargoCrates.ps1. Replaces the Mxc-Azure-Feed cargo registry.'
    }
    & gh release upload $Tag -R $Repo --clobber $pkg "$pkg.sha256"
    if ($LASTEXITCODE) { throw 'gh release upload failed' }
}
