# Shared helpers for the darbotlm/rust_cargo scripts. Dot-source only.

function Get-RustCargoToken {
    foreach ($n in 'RUST_CARGO_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { return $v }
    }
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $t = (& gh auth token 2>$null)
        if ($LASTEXITCODE -eq 0 -and $t) { return $t.Trim() }
    }
    return $null
}

function Invoke-RustCargoDownload([string] $Url, [string] $OutFile, [switch] $Binary) {
    $headers = @{ 'User-Agent' = 'rust_cargo-installer'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $tok = Get-RustCargoToken
    if ($tok) { $headers.Authorization = "Bearer $tok" }
    if ($Binary) { $headers.Accept = 'application/octet-stream' }
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -Headers $headers -OutFile $OutFile -UseBasicParsing
}

function Get-RustCargoManifest([string] $Toolchain, [string] $Repo, [string] $ManifestPath) {
    if (-not $ManifestPath) {
        $local = Join-Path $PSScriptRoot "../toolchain/$Toolchain.json"
        if (Test-Path $local) { $ManifestPath = $local }
    }
    if (-not $ManifestPath) {
        $ManifestPath = Join-Path ([IO.Path]::GetTempPath()) "$Toolchain.json"
        Invoke-RustCargoDownload "https://api.github.com/repos/$Repo/contents/toolchain/$Toolchain.json?ref=main" $ManifestPath
        $j = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        [IO.File]::WriteAllBytes($ManifestPath, [Convert]::FromBase64String(($j.content -replace '\s', '')))
    }
    Get-Content $ManifestPath -Raw | ConvertFrom-Json
}

function Get-RustCargoHostTarget {
    $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $cpu = if ($arch -eq 'Arm64') { 'aarch64' } else { 'x86_64' }
    if ($IsMacOS) { return "$cpu-apple-darwin" }
    if ($IsLinux) { return "$cpu-unknown-linux-gnu" }
    return "$cpu-pc-windows-msvc"
}

function Get-RustCargoAsset($Repo, $Tag, $Asset, $WorkDir) {
    $out = Join-Path $WorkDir $Asset.name
    if (-not (Test-Path $out) -or (Get-FileHash $out -Algorithm SHA256).Hash -ne $Asset.sha256.ToUpper()) {
        $rel = Join-Path $WorkDir "release-$Tag.json"
        if (-not (Test-Path $rel)) { Invoke-RustCargoDownload "https://api.github.com/repos/$Repo/releases/tags/$Tag" $rel }
        $a = (Get-Content $rel -Raw | ConvertFrom-Json).assets | Where-Object name -eq $Asset.name
        if (-not $a) { throw "Release $Tag in $Repo has no asset $($Asset.name)" }
        Write-Host "  downloading $($Asset.name) ($([math]::Round($a.size / 1MB)) MB)"
        Invoke-RustCargoDownload $a.url $out -Binary
    }
    $h = (Get-FileHash $out -Algorithm SHA256).Hash
    if ($h -ne $Asset.sha256.ToUpper()) { Remove-Item $out -Force; throw "SHA-256 mismatch for $($Asset.name): got $h, expected $($Asset.sha256)" }
    return $out
}

# Unpacks a rust-lang dist tarball (rust-*.tar.xz / rust-std-*.tar.xz) into
# Destination. Mirrors install.sh: each component dir carries manifest.in with
# `file:` / `dir:` entries relative to the component root.
function Install-RustDistPackage([string] $Package, [string] $Destination, [string] $WorkDir, [string[]] $Exclude = @()) {
    $x = Join-Path $WorkDir ('x-' + [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($Package)))
    Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $x | Out-Null
    & tar -xf $Package -C $x
    if ($LASTEXITCODE) { throw "tar failed extracting $Package" }
    $root = Get-ChildItem $x -Directory | Select-Object -First 1
    foreach ($comp in Get-Content (Join-Path $root.FullName 'components')) {
        if (-not $comp -or ($Exclude | Where-Object { $comp -like $_ })) { continue }
        $cdir = Join-Path $root.FullName $comp
        foreach ($line in Get-Content (Join-Path $cdir 'manifest.in')) {
            $kind, $rel = $line -split ':', 2
            $src = Join-Path $cdir $rel; $dst = Join-Path $Destination $rel
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            if ($kind -eq 'dir') { Copy-Item $src (Split-Path $dst) -Recurse -Force } else { Copy-Item $src $dst -Force }
        }
    }
    Remove-Item $x -Recurse -Force
}
