<#
.SYNOPSIS
  Mirror an upstream Rust release into darbotlm/rust_cargo as darbot-<ver>.

.DESCRIPTION
  Downloads the official rust-lang dist tarballs for each host and rust-std
  target, verifies them against static.rust-lang.org's .sha256 sidecars,
  uploads them to the `toolchain-<ver>` release, and writes
  toolchain/darbot-<ver>.json (the manifest the installers verify against).
#>
[CmdletBinding()]
param(
    [string] $Version = '1.100.0',
    [string] $Repo = 'darbotlm/rust_cargo',
    [string[]] $Hosts = @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc', 'x86_64-unknown-linux-gnu', 'aarch64-apple-darwin', 'x86_64-apple-darwin'),
    [string[]] $StdTargets = @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc', 'x86_64-unknown-linux-gnu', 'aarch64-unknown-linux-gnu', 'aarch64-apple-darwin', 'x86_64-apple-darwin'),
    [string] $WorkDir = (Join-Path ([IO.Path]::GetTempPath()) "rust_cargo-$Version"),
    [switch] $SkipUpload
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$tag = "toolchain-$Version"

function Get-Verified([string] $file) {
    $url = "https://static.rust-lang.org/dist/$file"
    $out = Join-Path $WorkDir $file
    $c = (Invoke-WebRequest "$url.sha256" -UseBasicParsing).Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::ASCII.GetString($c) }
    $want = ($c.Trim() -split '\s+')[0]
    if (-not (Test-Path $out) -or (Get-FileHash $out -Algorithm SHA256).Hash -ne $want.ToUpper()) {
        Write-Host "  fetching $file"
        Invoke-WebRequest $url -OutFile $out -UseBasicParsing
    }
    $got = (Get-FileHash $out -Algorithm SHA256).Hash
    if ($got -ne $want.ToUpper()) { throw "upstream SHA-256 mismatch for $file" }
    [ordered]@{ name = $file; sha256 = $got.ToLower(); size = (Get-Item $out).Length; upstream = $url }
}

$hostMap = [ordered]@{}; foreach ($h in $Hosts) { $hostMap[$h] = Get-Verified "rust-$Version-$h.tar.xz" }
$stdMap = [ordered]@{}; foreach ($t in $StdTargets) { $stdMap[$t] = Get-Verified "rust-std-$Version-$t.tar.xz" }

# Learn the exact rustc commit from the Windows/Linux host package's version file.
$probe = $hostMap.Values | Select-Object -First 1
$vx = Join-Path $WorkDir 'probe'; Remove-Item $vx -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $vx | Out-Null
& tar -xf (Join-Path $WorkDir $probe.name) -C $vx --include '*/version'
$verLine = (Get-Content (Get-ChildItem $vx -Recurse -Filter version | Select-Object -First 1).FullName -Raw).Trim()
$commit = ([regex]::Match($verLine, '\(([0-9a-f]{9})')).Groups[1].Value

$manifest = [ordered]@{
    toolchain         = "darbot-$Version"
    rustVersion       = $Version
    rustcVersion      = $verLine
    rustcCommit       = $commit
    releaseTag        = $tag
    replaces          = 'ms-prod-1.93 (Mxc-Azure-Feed)'
    excludeComponents = @('rust-docs*')
    host              = $hostMap
    std               = $stdMap
}
$mPath = Join-Path $PSScriptRoot "../toolchain/darbot-$Version.json"
New-Item -ItemType Directory -Force (Split-Path $mPath) | Out-Null
$manifest | ConvertTo-Json -Depth 6 | Set-Content $mPath -Encoding utf8
Write-Host "manifest -> $mPath ($verLine)"

if (-not $SkipUpload) {
    & gh release view $tag -R $Repo *> $null
    if ($LASTEXITCODE) {
        & gh release create $tag -R $Repo --title "darbot-$Version (Rust $Version)" --notes "Verified mirror of the official Rust $Version dist packages. Install with scripts/Install-RustCargoToolchain.ps1 -Toolchain darbot-$Version. Replaces ms-prod-1.93 from Mxc-Azure-Feed."
    }
    $files = @($hostMap.Values + $stdMap.Values | ForEach-Object { Join-Path $WorkDir $_.name })
    & gh release upload $tag -R $Repo --clobber @files
    if ($LASTEXITCODE) { throw 'gh release upload failed' }
}
