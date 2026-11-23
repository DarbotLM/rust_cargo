#!/usr/bin/env bash
# Install a pinned darbot Rust toolchain from darbotlm/rust_cargo (Linux/macOS).
# Usage: install-rustcargo-toolchain.sh [darbot-1.100.0] [extra-target ...]
# Needs: curl, jq, tar(xz), rustup, sha256sum|shasum. Token: RUST_CARGO_TOKEN|GH_TOKEN|GITHUB_TOKEN|gh.
set -euo pipefail
TOOLCHAIN="${1:-darbot-1.100.0}"; shift || true
REPO="${RUST_CARGO_REPO:-darbotlm/rust_cargo}"
ROOT="${RUST_CARGO_HOME:-$HOME/.rust_cargo}"
TOKEN="${RUST_CARGO_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}}}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

api() { curl -fsSL -H "User-Agent: rust_cargo-installer" ${TOKEN:+-H "Authorization: Bearer $TOKEN"} "$@"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) HOST=x86_64-unknown-linux-gnu ;; Linux-aarch64) HOST=aarch64-unknown-linux-gnu ;;
  Darwin-arm64) HOST=aarch64-apple-darwin ;;     Darwin-x86_64) HOST=x86_64-apple-darwin ;;
  *) echo "unsupported host $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

manifest="$here/../toolchain/$TOOLCHAIN.json"
if [[ ! -f "$manifest" ]]; then
  manifest="$(mktemp)"; api -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/$REPO/contents/toolchain/$TOOLCHAIN.json?ref=main" -o "$manifest"
fi
TAG="$(jq -r .releaseTag "$manifest")"; COMMIT="$(jq -r .rustcCommit "$manifest")"
WORK="$ROOT/downloads/$TOOLCHAIN"; DEST="$ROOT/toolchains/$TOOLCHAIN-$HOST"; mkdir -p "$WORK"
rel="$WORK/release.json"; api "https://api.github.com/repos/$REPO/releases/tags/$TAG" -o "$rel"

fetch() { # $1=json path (host.X / std.X)
  local name want url out
  name="$(jq -r ".$1.name // empty" "$manifest")"; [[ -n "$name" ]] || { echo "no package for $1" >&2; exit 1; }
  want="$(jq -r ".$1.sha256" "$manifest")"; out="$WORK/$name"
  if [[ ! -f "$out" || "$(sha "$out")" != "$want" ]]; then
    url="$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .url' "$rel")"
    echo "  downloading $name"; api -H "Accept: application/octet-stream" "$url" -o "$out"
  fi
  [[ "$(sha "$out")" == "$want" ]] || { echo "SHA-256 mismatch for $name" >&2; rm -f "$out"; exit 1; }
  echo "$out"
}
unpack() { # $1=pkg
  local x; x="$(mktemp -d)"; tar -xf "$1" -C "$x"
  "$x"/*/install.sh --prefix="$DEST" --without=rust-docs --disable-ldconfig >/dev/null
  rm -rf "$x"
}

if [[ ! -x "$DEST/bin/rustc" ]] || ! "$DEST/bin/rustc" -V | grep -q "$COMMIT"; then
  rm -rf "$DEST"; mkdir -p "$DEST"; unpack "$(fetch "host[\"$HOST\"]")"
fi
for t in "$@"; do
  [[ "$t" == "$HOST" || -d "$DEST/lib/rustlib/$t" ]] && continue
  echo "Adding rust-std for $t"; unpack "$(fetch "std[\"$t\"]")"
done
"$DEST/bin/rustc" -V | grep -q "$COMMIT" || { echo "rustc commit mismatch" >&2; exit 1; }
rustup toolchain link "$TOOLCHAIN" "$DEST"
if [[ -n "${TF_BUILD:-}" ]]; then echo "##vso[task.setvariable variable=RUSTUP_TOOLCHAIN]$TOOLCHAIN"; fi
if [[ -n "${GITHUB_ENV:-}" ]]; then echo "RUSTUP_TOOLCHAIN=$TOOLCHAIN" >> "$GITHUB_ENV"; fi
echo "OK: $("$DEST/bin/rustc" -V) -> $TOOLCHAIN ($DEST)"
