# Building `lore-server` for aarch64 (Raspberry Pi 4)

Reference guide for cross-compiling this fork's (`lore-rpi`) `loreserver`
binary for a Raspberry Pi 4, on every sync with upstream (`EpicGames/lore`).
Written to be followed by a person or an AI agent alike. Complements
[lore-aarch64-build.md](lore-aarch64-build.md), which covers the build
environment and the `lore` CLI.

> **One-sentence summary:** `loreserver` builds for
> `aarch64-unknown-linux-musl` via `cargo-zigbuild`, with no manual
> `RUSTFLAGS` — the only thing needed is the `zerocopy` feature on `uuid` in
> `lore-server/Cargo.toml`, already applied in this fork.

---

## 1. Environment

### Target
| Item | Value |
|------|-------|
| Hardware | Raspberry Pi 4 (Argon EON NAS) |
| CPU | ARM Cortex-A72 (ARMv8-A, **no** SVE) |
| Architecture | ARM64 / aarch64 |
| OS | Debian 11 (Bullseye) |
| glibc | 2.31 |

> **Why `musl` and not `gnu`?** The target runs glibc 2.31. Linking with
> `aarch64-unknown-linux-gnu` on the host would tie the binary to the host's
> (newer) glibc, causing `GLIBC_2.3x not found` errors on the Pi. Using
> `aarch64-unknown-linux-musl` produces a static binary independent of glibc,
> which runs on any aarch64 userland. It's the more robust choice for a NAS
> with an old OS.

### Build host
| Tool | Note |
|------|------|
| Host OS | WSL2 + Arch Linux (any Linux x86_64 works) |
| `cargo-zigbuild` | wrapper that uses `zig` as the cross linker |
| `zig` | provides the C toolchain/cross-linking |
| Rust target | `aarch64-unknown-linux-musl` (`rustup target add aarch64-unknown-linux-musl`) |

Quick host check before building:

```bash
rustc --version
cargo zigbuild --version
zig version
rustup target list --installed | grep aarch64-unknown-linux-musl
```

---

## 2. Build command (the source of truth)

```bash
cd /mnt/c/dev/repos/lore-rpi
cargo zigbuild --release --target aarch64-unknown-linux-musl --bin loreserver
```

The binary lands at:

```
target/aarch64-unknown-linux-musl/release/loreserver
```

⚠️ No `RUSTFLAGS` needed. The `--cfg tokio_unstable` and `--cfg
uuid_unstable` that `loreserver` requires are already checked into
`.cargo/config.toml` (the `[build]` section), which applies automatically to
any target — like `aarch64-unknown-linux-musl` — that doesn't have its own
`[target.*]` table in that file. This differs from the v0.8.3 state, when
these cfgs had to be passed manually (see this doc's git history if you want
the details of why).

---

## 3. The one fix that's still needed

### `zerocopy` feature on `uuid` in `lore-server/Cargo.toml`

| Field | Detail |
|-------|--------|
| File | `lore-server/Cargo.toml` |
| Original (upstream) | `uuid = { workspace = true }` |
| Fixed (in this fork) | `uuid = { workspace = true, features = ["zerocopy"] }` |
| Type | Cargo.toml edit |
| Status | **Already applied** in this fork |

**Root cause:** `ReplicationHeader`
(`lore-server/src/protocol/replication_store/header.rs`) derives zerocopy
traits on a `Uuid` field. That requires the `uuid` crate to have its
`zerocopy` feature enabled. The `lore-base`, `lore-revision`, and
`lore-storage` crates already do this; only `lore-server` had the
inconsistency.

**Why the cfg alone (`uuid_unstable`) wasn't enough:** enabling the
`zerocopy` *feature* only pulls in the *dependency*. The `impl
IntoBytes/FromBytes/Immutable for Uuid` in the `uuid` crate sit behind
**two** conditions together — `all(uuid_unstable, feature = "zerocopy")`.
`--cfg uuid_unstable` was already resolved in the workspace's
`.cargo/config.toml`; exactly the feature was missing in `lore-server`'s
`Cargo.toml`. See
[uuid-rs/uuid#588](https://github.com/uuid-rs/uuid/issues/588).

**Upstream status:** still a real inconsistency in `EpicGames/lore` (the
other three workspace crates already get it right) — a PR candidate.

### Re-check after an upstream sync

```bash
grep -n '^uuid' lore-server/Cargo.toml
# compare against the crates that already get it right:
grep -n '^uuid' lore-base/Cargo.toml lore-revision/Cargo.toml lore-storage/Cargo.toml
```

If `lore-server` already has `features = ["zerocopy"]` (for example, because
upstream accepted the PR, or because the merge brought in this fork's patch
with no conflict), do nothing.

---

## 4. Fixes that are now obsolete (history — do not reapply)

These two existed when this runbook was written against v0.8.3. Between
v0.8.3 and v0.10.0 upstream fixed both. Documented here only so you don't
reintroduce them thinking "it was always like this":

- **Hardcoded `-mcpu=neoverse-512tvb` in `lore-base/build.rs`:** became
  opt-in, behind `lore-base`'s `neoverse-512tvb` feature. A normal aarch64
  build no longer receives this `-mcpu`, so it doesn't break on CPUs without
  SVE-512 like the Cortex-A72 — no patch needed.
- **`--cfg tokio_unstable` / `--cfg uuid_unstable` via manual `RUSTFLAGS`:**
  both are now checked into the repository's `.cargo/config.toml`
  `[build].rustflags`.

If after a future sync the build fails again with `unknown CPU` or with an
`unresolved import` gated by `cfg(tokio_unstable)`/`cfg(uuid_unstable)`,
that's a sign upstream restructured this mechanism again — treat it as a new
problem, don't blindly reapply the old patches.

---

## 5. Verification on the target (Pi 4)

After copying the binary to the Pi:

```bash
file ./loreserver
# Expected: ELF 64-bit LSB ... ARM aarch64 ...  (static, if musl)

./loreserver --version    # or --help
```

Recommended minimal smoke test: bring the service up with a local config
(`config/local.toml`) and confirm it starts and answers the health check
before promoting to production.

---

## 6. Invariants and pitfalls

- **On-the-wire format (CRITICAL).** `ReplicationHeader` is part of the
  replication protocol; its byte layout **must not change**. The chosen
  approach (enabling `uuid_unstable`/the `zerocopy` feature and using
  `uuid`'s real impl) preserves the byte-for-byte layout and is identical to
  upstream's build. **Avoid** swapping `Uuid` for `[u8; 16]` in the header as
  a workaround — it works, but requires editing every call site of
  `.as_hyphenated()`/`.to_string()`/`Uuid::new_v4()` in the replication
  services and tests, and introduces a risk of format divergence. Only
  consider it if `uuid_unstable` is removed upstream with no replacement.
- **`cargo-zigbuild` is required** (not plain `cargo build`) for musl
  cross-linking via `zig`.
- If you want to tune specifically for the Cortex-A72 (instead of the
  portable baseline upstream uses by default for
  `aarch64-unknown-linux-gnu`), see the note about `-mcpu` in
  [lore-aarch64-build.md § 6.2](lore-aarch64-build.md#62--optional-cpu-tuning-for-the-cortex-a72)
  — the right value depends on the C toolchain (`zig cc` via zigbuild
  requires different syntax from a real `gcc`) and needs to be validated
  empirically before settling on one.

---

## 7. Candidates for an upstream PR

1. `lore-server/Cargo.toml`: missing `features = ["zerocopy"]` on `uuid`
   (inconsistent with `lore-base`, `lore-revision`, and `lore-storage`,
   which already do this).

---

## 8. Automated build and distribution

This document covers the manual build (WSL + `cargo zigbuild` directly). For
the same build running in CI (GitHub Actions) on every release, and for
installing or updating an already-published `loreserver` on a Pi, see
[lore-rpi-release.md](lore-rpi-release.md).
