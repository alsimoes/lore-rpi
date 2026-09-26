# `lore-rpi` releases and installation

Runbook for publishing a release of this fork (`lore-rpi`) and for
installing or updating an already-installed `lore` (CLI) and `loreserver` on
a Raspberry Pi 4 / Argon EON. Complements
[lore-aarch64-build.md](lore-aarch64-build.md) and
[lore-server-aarch64-build.md](lore-server-aarch64-build.md), which cover
the manual build via WSL — this document covers the automated build (GitHub
Actions) and distributing the finished binaries.

---

## 1. Overview

- **Build:** a workflow (`.github/workflows/release-rpi.yml`) cross-builds
  `lore` and `loreserver` for `aarch64-unknown-linux-musl` on a GitHub
  Actions `ubuntu-latest` runner — it doesn't depend on the local WSL
  machine. It installs the Rust target, `zig` (pinned by version + sha256),
  and `cargo-zigbuild` (pinned by version), runs the same command documented
  in
  [lore-server-aarch64-build.md §2](lore-server-aarch64-build.md#2-build-command-the-source-of-truth),
  packages the two binaries as `.tar.gz`, and publishes (or updates) a
  GitHub Release on `alsimoes/lore-rpi` with both files.
- **Install/update:** `scripts/install-rpi.sh`, a new script specific to this
  fork (it doesn't touch `scripts/install.sh`, which is upstream's and
  points at `EpicGames/lore`/glibc). It downloads the latest release (or a
  specific tag) and installs/updates `lore` and/or `loreserver` into `~/bin`
  on the Pi itself.
- None of this is sent to upstream (`EpicGames/lore`) — both files are
  additive and live only in this fork, so there's no merge-conflict risk on
  syncs (the same philosophy as the other documents in `aarch64-docs/`).

---

## 2. Publishing a release

### 2.1 — Tag naming

This fork's tags use the format `vX.Y.Z-rpi.N`, never plain `vX.Y.Z` —
upstream already uses `vX.Y.Z` for its own tags (`v0.8.3` .. `v0.10.0`,
etc.), and those tags can end up fetched into this repository via `git fetch
origin` (the `lore-upstream` remote already has them). The `-rpi.N` suffix
avoids collision/ambiguity:

- `X.Y.Z` = the upstream version being packaged (`git describe` or whatever
  is in `Cargo.toml`/`lore --version` at build time).
- `N` = this fork's counter, starting at `1`, incremented for every new
  release built from the same `X.Y.Z` (e.g., a fork-only patch with no
  upstream change).

Example: `v0.10.0-rpi.1`.

### 2.2 — Triggering the workflow

Two ways:

**a) Push the tag** (the normal path):

```bash
git tag v0.10.0-rpi.1
git push origin v0.10.0-rpi.1
```

Pushing the tag triggers `.github/workflows/release-rpi.yml` automatically.

**b) `workflow_dispatch`** (re-run an existing tag, e.g. after a build that
failed due to runner flakiness):

```bash
gh workflow run release-rpi.yml -f tag=v0.10.0-rpi.1
```

Running it again over the same tag is safe — the last step does `gh release
upload --clobber` if the Release already exists, instead of failing.

### 2.3 — Watching and verifying

```bash
gh run watch --repo alsimoes/lore-rpi
gh release view v0.10.0-rpi.1 --repo alsimoes/lore-rpi
```

Confirm the Release has both assets:

```
lore-v0.10.0-rpi.1-aarch64-unknown-linux-musl.tar.gz
loreserver-v0.10.0-rpi.1-aarch64-unknown-linux-musl.tar.gz
```

⚠️ **`gh auth status` needs to be valid** for the `gh` commands above (the
workflow itself uses the Action's automatic `GITHUB_TOKEN`, not your local
session — only the commands you run manually from your terminal need `gh
auth login`/`gh auth refresh`).

### 2.4 — If the build fails

- **Outdated `zig`/`cargo-zigbuild`:** the workflow pins
  `ZIG_VERSION`/`ZIG_SHA256`/`CARGO_ZIGBUILD_VERSION` at the top of the file.
  Updating requires fetching the new sha256 from
  `https://ziglang.org/download/index.json` (key `<version>.x86_64-linux.shasum`)
  and the new tag from `https://github.com/rust-cross/cargo-zigbuild/releases`.
- **New compile error after an upstream sync:** review
  [lore-aarch64-build.md §6](lore-aarch64-build.md#6-the-fix-thats-still-needed-re-check-every-sync-️)
  first — it's likely the same class of incompatibility described there
  (e.g., a missing `uuid` feature on some new crate).

---

## 3. Installing or updating on the Pi

Run directly on the Argon EON (or any `aarch64` Linux host):

```bash
# Install/update both binaries (lore + loreserver):
curl -fsSL https://raw.githubusercontent.com/alsimoes/lore-rpi/main/scripts/install-rpi.sh | bash

# Client only:
curl -fsSL https://raw.githubusercontent.com/alsimoes/lore-rpi/main/scripts/install-rpi.sh | bash -s -- --client-only

# Server only, from a specific tag:
curl -fsSL https://raw.githubusercontent.com/alsimoes/lore-rpi/main/scripts/install-rpi.sh | bash -s -- --server-only --version v0.10.0-rpi.1
```

Re-running the same command later (with no `--version`) updates to the
latest `latest` release — it's the same path for installing and for
updating; the script already detects and reports whether it's installing
for the first time or replacing an existing binary.

Script defaults (see `install-rpi.sh --help` for the full list):

| Flag | Default |
|------|---------|
| install destination | `~/bin` (already on `PATH` via `.profile` on stock Debian) |
| repository | `alsimoes/lore-rpi` |
| version | `latest` |
| platform | fixed to `aarch64-unknown-linux-musl` — there's no OS/arch table like upstream's `scripts/install.sh`, because this fork only ever publishes that single triple |

⚠️ If `loreserver` is running at the time of the update, the script doesn't
restart the process itself (there's no systemd service defined in this
repository) — restart it manually after updating.

---

## 4. Why not edit `scripts/install.sh` instead of adding a new file

`scripts/install.sh` is upstream's: it assumes glibc (`unknown-linux-gnu`),
is multi-platform (Darwin/x86_64 included), and defaults to
`EpicGames/lore`. Editing that file for musl/aarch64/`alsimoes/lore-rpi`
would work, but would create a conflict (or worse, a silent merge that
reverts the behavior) on every upstream sync — the same reason this fork's
other adaptations live in new files wherever possible (see
[lore-aarch64-build.md §1](lore-aarch64-build.md#1-why-cross-compile-and-not-download-a-binary-or-build-on-the-pi)
and the general pattern of the documents in `aarch64-docs/`).
`install-rpi.sh` is additive — nothing upstream references that name, so a
sync never touches it.

---

## 5. References

- Upstream: https://github.com/EpicGames/lore
- This fork: https://github.com/alsimoes/lore-rpi
- Release workflow: `.github/workflows/release-rpi.yml`
- Install script: `scripts/install-rpi.sh`
- Upstream's install script (don't confuse the two): `scripts/install.sh`
- Zig releases index: https://ziglang.org/download/index.json
- cargo-zigbuild releases: https://github.com/rust-cross/cargo-zigbuild/releases
