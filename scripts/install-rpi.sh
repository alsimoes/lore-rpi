#!/usr/bin/env bash
# Install or update the lore CLI and/or loreserver, built for
# aarch64-unknown-linux-musl, from this fork's GitHub Releases
# (alsimoes/lore-rpi). Run this ON the target device (Raspberry Pi 4 / Argon
# EON, Debian 11) — see aarch64-docs/ for how the releases are built.
#
# Quick start:
#   curl -fsSL https://raw.githubusercontent.com/alsimoes/lore-rpi/main/scripts/install-rpi.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/alsimoes/lore-rpi/main/scripts/install-rpi.sh | bash -s -- --server-only
#
# Re-running installs the latest release over whatever is already there, so
# this doubles as the update path for both binaries.
#
# For flags and their env-var equivalents, run with --help.

set -euo pipefail

REPO="${LORE_REPO:-alsimoes/lore-rpi}"
VERSION="${LORE_VERSION:-latest}"
INSTALL_DIR="${LORE_INSTALL_DIR:-$HOME/bin}"
TOKEN="${GITHUB_TOKEN:-}"
TARGET="aarch64-unknown-linux-musl"
CLIENT=1
SERVER=1

say() { printf '%s\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }

usage() {
    cat >&2 <<'EOF'
Install or update the lore CLI and/or loreserver from this fork's releases
(alsimoes/lore-rpi), built for aarch64-unknown-linux-musl (Raspberry Pi 4 /
Argon EON, Debian 11).

Usage: install-rpi.sh [--client-only] [--server-only] [--version <v>] [--install-dir <dir>] [--repo <owner/repo>] [--token <t>]

Every flag has an env-var equivalent (except --client-only/--server-only);
the flag wins when both are set:

  --client-only                            install/update only the lore CLI
  --server-only                            install/update only loreserver
  --version <v>        LORE_VERSION        release tag to install (default: latest)
  --install-dir <dir>  LORE_INSTALL_DIR    where binaries go (default: ~/bin)
  --repo <owner/repo>  LORE_REPO           source repository (default: alsimoes/lore-rpi)
  --token <t>          GITHUB_TOKEN        token for a private repo / higher rate limit (defaults to `gh auth token`)
  -h, --help                               show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --client-only) SERVER=0 ;;
        --server-only) CLIENT=0 ;;
        --version) VERSION="${2:?--version needs a value}"; shift ;;
        --install-dir) INSTALL_DIR="${2:?--install-dir needs a value}"; shift ;;
        --repo) REPO="${2:?--repo needs a value}"; shift ;;
        --token) TOKEN="${2:?--token needs a value}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

[[ "$CLIENT" == 1 || "$SERVER" == 1 ]] || die "--client-only and --server-only are mutually exclusive"

for tool in curl tar; do
    command -v "$tool" >/dev/null || die "$tool is required but not installed"
done

# This fork only ever builds one triple (see .github/workflows/release-rpi.yml),
# so unlike upstream's install.sh there is no OS/arch table to pick from.
case "$(uname -s)" in
    Linux) ;;
    *) die "this fork only ships Linux/$TARGET builds; unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) ;;
    *) die "this fork only ships $TARGET builds; unsupported architecture $(uname -m)" ;;
esac

# Fall back to the gh CLI's token when none was supplied — installing from a
# private repo then just needs an existing `gh auth login`, not a hand-made PAT.
# Pin github.com: we only ever call api.github.com, and gh may be active on a
# different host (e.g. an enterprise GHE), whose token would not authenticate.
if [[ -z "$TOKEN" ]] && command -v gh >/dev/null; then
    TOKEN="$(gh auth token --hostname github.com 2>/dev/null || true)"
    [[ -n "$TOKEN" ]] && say "using GitHub token from gh CLI"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# GET a GitHub URL, using the token when present to lift the API rate limit.
gh_get() { curl -fsSL ${TOKEN:+--oauth2-bearer "$TOKEN"} "$@"; }

# Fetch the release metadata JSON once (latest, or the requested tag).
fetch_release() {
    local api="https://api.github.com/repos/$REPO/releases"
    if [[ "$VERSION" == latest ]]; then api+="/latest"; else api+="/tags/$VERSION"; fi
    gh_get "$api"
}

# Print the API asset URL for <binary>'s tarball matching this platform. We resolve
# the asset's api.github.com URL (not its browser_download_url) so a private-repo
# asset can download with a token via Accept: application/octet-stream. RS=","
# splits the JSON on fields (whitespace-independent) and relies on GitHub
# emitting each asset's "url" before its "name".
asset_url() {
    awk -v bin="$1" -v triple="$TARGET" '
        BEGIN { RS = "," }
        /"url"[[:space:]]*:[[:space:]]*"https:\/\/api\.github\.com\/[^"]*\/releases\/assets\/[0-9]+"/ {
            u = $0; sub(/.*"url"[[:space:]]*:[[:space:]]*"/, "", u); sub(/".*/, "", u)
        }
        $0 ~ ("\"name\"[[:space:]]*:[[:space:]]*\"" bin "-v?[0-9][^\"]*-" triple "\\.tar\\.gz\"") { print u; exit }
    ' <<<"$RELEASE_JSON"
}

# Download, unpack, and install <binary> into $INSTALL_DIR, replacing any existing copy.
install_binary() {
    local binary="$1" url
    local bin_path="$INSTALL_DIR/$binary"
    url="$(asset_url "$binary")" || true
    [[ -n "$url" ]] || die "no $binary release found for $TARGET (repo=$REPO version=$VERSION)"

    if command -v "$binary" >/dev/null; then
        say "$("$binary" --version 2>/dev/null || echo "$binary") found — updating"
    else
        say "installing $binary"
    fi

    curl -fL --progress-bar ${TOKEN:+--oauth2-bearer "$TOKEN"} \
        -H "Accept: application/octet-stream" -o "$WORK/$binary.tar.gz" "$url"
    # Extract into a per-binary dir and find the executable, so this works whether
    # the tarball holds the binary at its root or under a versioned subdirectory.
    local dest="$WORK/$binary.d"
    mkdir -p "$dest"
    tar -xzf "$WORK/$binary.tar.gz" -C "$dest"
    local extracted
    extracted="$(find "$dest" -type f -name "$binary" | head -n1)"
    [[ -n "$extracted" ]] || die "could not find $binary in the downloaded archive"
    install -m 0755 "$extracted" "$bin_path"
    say "installed $("$bin_path" --version 2>/dev/null || echo "$binary") -> $bin_path"
}

# Make sure $INSTALL_DIR is on PATH for this run, and persist it to the shell rc if missing.
ensure_on_path() {
    case ":$PATH:" in *":$INSTALL_DIR:"*) return ;; esac
    export PATH="$INSTALL_DIR:$PATH"

    local rc line marker="# added by lore install-rpi.sh"
    case "$(basename "${SHELL:-}")" in
        zsh)  rc="$HOME/.zshrc"                   ; line="export PATH=\"$INSTALL_DIR:\$PATH\"  $marker" ;;
        bash) rc="$HOME/.bashrc"                  ; line="export PATH=\"$INSTALL_DIR:\$PATH\"  $marker" ;;
        fish) rc="$HOME/.config/fish/config.fish" ; line="fish_add_path \"$INSTALL_DIR\"  $marker" ;;
        *)    rc="$HOME/.profile"                 ; line="export PATH=\"$INSTALL_DIR:\$PATH\"  $marker" ;;
    esac
    mkdir -p "$(dirname "$rc")"
    # Dedup on $INSTALL_DIR (not the marker) so a different --install-dir still persists.
    grep -qsF "$INSTALL_DIR" "$rc" || printf '\n%s\n' "$line" >> "$rc"
    say "added $INSTALL_DIR to PATH in $rc — restart your shell to pick it up"
}

mkdir -p "$INSTALL_DIR"

# Fetch release metadata once; every install_binary call greps it. Surface the
# real curl error (404/403/network) here instead of masking it as the later
# friendly per-binary "no … release found", which means something different.
if ! RELEASE_JSON="$(fetch_release 2>&1)"; then
    die "could not fetch $VERSION release for $REPO:
$RELEASE_JSON
hint: for a private repo set GITHUB_TOKEN or run 'gh auth login'"
fi

[[ "$CLIENT" == 1 ]] && install_binary lore
[[ "$SERVER" == 1 ]] && install_binary loreserver
ensure_on_path

say ""
say "Done."
if [[ "$SERVER" == 1 ]]; then
    say "If loreserver is currently running, restart it manually to pick up the new binary."
fi
