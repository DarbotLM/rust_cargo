# rust_cargo

darbotlm's pinned Rust toolchain and crate mirror. It replaces the internal
`ms-prod-<ver>` toolchains and the cargo registry on **Mxc-Azure-Feed** for
darbotlm projects (MXC, bitscoop, scooper).

| What | Where | Consumed by |
|---|---|---|
| Rust toolchain `darbot-1.100.0` | release `toolchain-1.100.0`, manifest `toolchain/darbot-1.100.0.json` | `scripts/Install-RustCargoToolchain.ps1`, `scripts/install-rustcargo-toolchain.sh` |
| Vendored crates.io sources | release `crates`, assets `crates-<lock16>.tar.gz` (+`.sha256`), index `crates/index.json` | `scripts/Use-RustCargoCrates.ps1` |
| Azure Pipelines templates | `azure-pipelines/*.yml` | MXC `.azure-pipelines/templates` |

All artifacts are SHA-256 verified before they're unpacked. Toolchain
packages are byte-identical to the official `static.rust-lang.org` dist
tarballs. Each one's upstream URL and hash is recorded in the manifest.

## Install the toolchain

```powershell
./scripts/Install-RustCargoToolchain.ps1 -Toolchain darbot-1.100.0 -AdditionalTargets aarch64-pc-windows-msvc
cargo +darbot-1.100.0 build --locked
```

```bash
./scripts/install-rustcargo-toolchain.sh darbot-1.100.0 aarch64-unknown-linux-gnu
```

The toolchain is installed under `~/.rust_cargo/toolchains` (override with
`RUST_CARGO_HOME`) and registered with `rustup toolchain link`. In Azure
Pipelines the scripts also set `RUSTUP_TOOLCHAIN`, which overrides a repo's
`rust-toolchain.toml`.

## Use the crate mirror

```powershell
./scripts/Use-RustCargoCrates.ps1 -LockFile src/Cargo.lock -ConfigFile .cargo/config.toml
cargo build --locked --offline
```

## Publish

```powershell
./scripts/Publish-RustCargoToolchain.ps1 -Version 1.100.0        # mirror + verify + upload + manifest
./scripts/Publish-RustCargoCrates.ps1 -WorkspaceDir G:\mxc\src   # vendor + upload, keyed by Cargo.lock
```

Commit the updated `toolchain/*.json` and `crates/index.json` after
publishing.

## Auth

The repo is private. Scripts read `RUST_CARGO_TOKEN`, `GH_TOKEN`,
`GITHUB_TOKEN`, or `gh auth token`. Pipelines take the secret variable
`RustCargoToken`.

## Mapping from Mxc-Azure-Feed

| Mxc-Azure-Feed | rust_cargo |
|---|---|
| `templateContext.rust.rustToolchain` `version: 'ms-prod-1.93'` | `template: Rust.Toolchain.RustCargo.yml` `toolchain: darbot-1.100.0` |
| `Cargo.Setup.Private.yml` + `CargoAuthenticate@0` | `template: Cargo.Setup.RustCargo.yml` |
| `[source.crates-io] replace-with = "Mxc-Azure-Feed"` | `replace-with = "rust-cargo"` (directory source, offline) |
