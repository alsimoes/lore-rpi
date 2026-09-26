# Building Lore for ARM64 (Raspberry Pi 4 / Argon EON)

Runbook for cross-compiling Lore from this fork's source (`lore-rpi`) to run
on a Raspberry Pi 4. Written to be followed at every upstream merge, by a
person or by an AI agent with no context on the original investigation.

**Last verified:** `main` @ `a0286e9` (post `v0.10.0` release, ~531 commits
ahead of v0.8.3 where this runbook started). Sections marked ⚠️ are points
where behavior may change between upstream merges — always re-check them,
don't assume they still hold.

> **Important update:** of the four incompatibilities originally found in
> v0.8.3, three have already been fixed upstream (see §6). Only one real fix
> remains: the missing `zerocopy` feature on `lore-server`'s `uuid`. That
> patch is already applied in this fork (`lore-rpi`). This document exists so
> you don't needlessly reintroduce the other three "fixes" when syncing with
> upstream, and so you know how to reconfirm the one that's left.

---

## 1. Why cross-compile (and not download a binary or build on the Pi)

Two facts justify the rest of this document:

- **There is no generic ARM64 binary in upstream's official releases**
  (`EpicGames/lore`). ⚠️ Check the releases page on every sync: if a generic
  ARM64 or `cortex-a72` asset shows up, most of this runbook becomes
  unnecessary — just download it.

- **Building on the Pi itself is risky.** The Pi 4 has 1.8 GB of RAM and
  minimal swap. Lore's dependency tree is large (AWS SDK, gRPC/tonic,
  OpenTelemetry, cryptography). The real risk is running out of memory during
  the *linking* phase (which loads everything at once), not during
  incremental compilation. There's also little free disk space on the SD
  card. Cross-compiling on the desktop and copying the finished binary avoids
  both problems.

- **The target's glibc is old.** The Argon EON runs Debian 11 (Bullseye),
  **glibc 2.31**. Any binary dynamically linked against a newer glibc fails
  on the target with errors like `version 'GLIBC_2.xx' not found`. The fix is
  to compile **statically against musl** (target `aarch64-unknown-linux-musl`),
  which eliminates the dependency on the target system's glibc entirely.

---

## 2. Build environment (host)

- **Host OS:** Windows + WSL2, **Arch Linux** distro.
  - There's also an Ubuntu distro installed in WSL, but the toolchain was set
    up on Arch. Use Arch: `wsl -d archlinux`.
  - ⚠️ The Arch distro imported into WSL runs as **root** by default
    (`[root@...]` prompt) and **has no `sudo`**. Run admin commands directly,
    with no `sudo` in front. If a script has `sudo`, remove it.
  - ⚠️ systemd needs to be enabled in WSL for `pacman-key`/`gpg-agent` to work
    (see section 4). Confirm with `ps -p 1 -o comm=` → should answer
    `systemd`.

- **Repository path:** the Windows clone shows up at `/mnt/c/...` inside WSL
  (e.g., `C:\dev\repos\lore-rpi` = `/mnt/c/dev/repos/lore-rpi`). **Always work
  from the `/mnt/c/...` path inside WSL**, never try to run the build
  commands in PowerShell — Windows' native Rust is a separate install and
  does NOT have the musl target, zig, or cargo-zigbuild.

- **Target:** Argon EON, IP `192.168.15.15`, user `alsimoes`, Debian 11
  ARM64, glibc 2.31, Cortex-A72 CPU.

---

## 3. Required toolchain (install once)

Inside Arch WSL, as root:

```bash
pacman -Syu --noconfirm
pacman -S --needed --noconfirm base-devel git openssh rustup aarch64-linux-gnu-gcc zig

rustup default stable
rustup target add aarch64-unknown-linux-musl
cargo install cargo-zigbuild
```

Confirm:

```bash
rustc --version
cargo --version
zig version
cargo zigbuild --version
ssh -V
```

Notes:
- `cargo-zigbuild` uses Zig as a universal cross-toolchain/linker. It's what
  makes the musl-ARM64 build viable without manually assembling a musl
  cross-linker (which isn't in Arch's official repos).
- `aarch64-linux-gnu-gcc` comes from Arch's official `extra` repository (no
  AUR needed).

---

## 4. Known environment issues (pacman/keyring)

If the toolchain install fails, it's almost always one of these:

**Slow mirror** (`error: failed retrieving file ... Operation too slow`):
swap the mirrorlist for Brazilian mirrors and force a re-sync with `-Syy`:

```bash
cat > /etc/pacman.d/mirrorlist << 'EOF'
Server = https://archlinux.c3sl.ufpr.br/$repo/os/$arch
Server = https://br.mirrors.cicku.me/archlinux/$repo/os/$arch
Server = https://mirror.ufscar.br/archlinux/$repo/os/$arch
EOF
pacman -Syy
```

**Outdated keyring** (`signature ... is unknown trust` / `invalid or
corrupted package (PGP signature)`): this is NOT download corruption — it's
`archlinux-keyring` being too old. Rebuild the keyring. This requires systemd
to be active (otherwise you get `agent_genkey failed: No such file or
directory`):

```bash
# 1) make sure systemd is enabled in WSL
cat > /etc/wsl.conf << 'EOF'
[boot]
systemd=true
EOF
# 2) in PowerShell: wsl --shutdown   then reopen:  wsl -d archlinux
# 3) confirm: ps -p 1 -o comm=   →  systemd
# 4) rebuild the keyring:
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring --noconfirm
```

---

## 5. Sync with upstream before building

This fork (`lore-rpi`) follows `EpicGames/lore`'s `main`. Before building,
sync and reconfirm the one remaining fix (§6):

```bash
cd /mnt/c/dev/repos/lore-rpi
git fetch origin
git status   # confirm it's clean before proceeding
```

⚠️ Unlike the original runbook (which pinned to a stable release tag), this
fork now deliberately tracks `main` — that's what we keep it synced for.
Still, after a large `git merge`/`rebase` from upstream, run a local build
before promoting to the Pi.

---

## 6. The fix that's still needed (re-check every sync ⚠️)

Of the four incompatibilities originally found in v0.8.3, three have already
been fixed by upstream itself between v0.8.3 and v0.10.0:

- **Hardcoded CPU in `lore-base/build.rs`:** the `-mcpu=neoverse-512tvb` that
  used to be forced unconditionally on any Linux ARM64 build is now only
  applied when the `lore-base` `neoverse-512tvb` feature is explicitly
  enabled (`--features lore-base/neoverse-512tvb`, see
  `.cargo/neoverse-512tvb.toml`). A normal build for
  `aarch64-unknown-linux-*` no longer receives any `-mcpu` that assumes SVE —
  the Pi 4's Cortex-A72 already compiles with no patch needed.
- **`--cfg tokio_unstable`:** already baked into `.cargo/config.toml`'s
  `[build].rustflags`, applied to any target that doesn't have its own
  `[target.*]` table (as is the case for `aarch64-unknown-linux-musl`).
- **`--cfg uuid_unstable`:** same — already in the same `[build].rustflags`.

In other words: **it's no longer necessary to pass `RUSTFLAGS` manually** nor
to edit `build.rs` to build for the Pi. All that's left:

### 6.1 — Missing `zerocopy` feature on uuid (lore-server/Cargo.toml)

**Symptom:** E0277 errors `the trait bound 'Uuid: IntoBytes' is not
satisfied` (and `FromBytes`, `Immutable`, `TryFromBytes`, `FromZeros`) in
`lore-server/src/protocol/replication_store/header.rs`.

**Cause:** the workspace declares `uuid` with `default-features = false`.
Crates that use zerocopy derives on `Uuid` need to explicitly enable the
`zerocopy` feature. `lore-base`, `lore-revision`, and `lore-storage` already
do this; `lore-server` didn't.

**Status in this fork:** already applied —
`lore-server/Cargo.toml` has `uuid = { workspace = true, features =
["zerocopy"] }`.

**How to tell if it's still needed after an upstream sync:**
```bash
grep -n "^uuid" lore-server/Cargo.toml
```
If it already has `features = ["zerocopy"]`, do nothing — upstream may have
fixed it too, or your merge already brought in this fork's patch.

### 6.2 — Optional CPU tuning for the Cortex-A72

Upstream has already established the pattern for this (the
`neoverse-512tvb` feature + `.cargo/neoverse-512tvb.toml`, see §3 above). If
you want the same performance gain for the Cortex-A72, the path is to mirror
that pattern: a `cortex-a72` feature in `lore-base/Cargo.toml`, the matching
`-mcpu` in `lore-base/build.rs` (gated by `CARGO_FEATURE_CORTEX_A72`), and a
`.cargo/cortex-a72.toml` with `rustflags = ["-C",
"target-cpu=cortex-a72"]`.

⚠️ **This has not been done in this fork yet** because the exact value
accepted by `-mcpu` depends on which C toolchain compiles `lore-base`'s
`rpmalloc.c` at build time — real `cc`/`gcc` accept `cortex-a72` (hyphen),
but `cargo-zigbuild` swaps `CC` for a `zig` wrapper, and `zig` has a history
of requiring `cortex_a72` (underscore) in this context (everything after the
first hyphen is read as a feature modifier). Don't implement this blindly —
test both on your toolchain (`zig targets | grep -i cortex`) before settling
on a value. Without this tweak, the build works normally; it just doesn't
have the CPU-specific tuning (equivalent to the "portable baseline" that
upstream itself uses as the default for `aarch64-unknown-linux-gnu`).

---

## 7. Build

```bash
cd /mnt/c/dev/repos/lore-rpi

# Client CLI (to run on the Pi as a client):
cargo zigbuild --release --target aarch64-unknown-linux-musl --bin lore

# Server (to host an instance on the Pi):
cargo zigbuild --release --target aarch64-unknown-linux-musl --bin loreserver
```

No `RUSTFLAGS` needed anymore (see §6) — the cfgs `loreserver` needs already
come from the repository's `.cargo/config.toml`.

Notes:
- The first build takes ~10-12 min (compiles the whole dependency tree).
- If you need a clean state after many attempts, `cargo clean` first (at the
  cost of recompiling everything).
- Binaries land in
  `target/aarch64-unknown-linux-musl/release/{lore,loreserver}`. Note the
  `musl` in the path — it's different from the `gnu` directory.

---

## 8. Verify the binary before copying it

```bash
file target/aarch64-unknown-linux-musl/release/lore
```

Expected: `ELF 64-bit LSB ... ARM aarch64 ... statically linked`. Confirming
"aarch64" and ideally "statically linked" (musl) avoids discovering an
incompatibility only after copying to the Pi.

---

## 9. Copy to the Argon EON and install

Prerequisite on the Pi: the `~/bin` directory needs to exist and be on PATH.
⚠️ `alsimoes`'s login shell is `sh`/dash (not bash), so PATH config lives in
`~/.profile` (which already has Debian's standard conditional block: `if [ -d
"$HOME/bin" ]; then PATH="$HOME/bin:$PATH"; fi`). Make sure `~/bin` exists:

```bash
ssh alsimoes@192.168.15.15 'mkdir -p ~/bin'
```

Copy (run from inside Arch WSL, which has the binary; it'll ask for a
password — with no SSH key configured, that's interactive and normal):

```bash
scp target/aarch64-unknown-linux-musl/release/lore alsimoes@192.168.15.15:~/bin/lore
# and/or:
scp target/aarch64-unknown-linux-musl/release/loreserver alsimoes@192.168.15.15:~/bin/loreserver
```

Make it executable and test (a new interactive session, so `.profile`'s
PATH applies):

```bash
ssh alsimoes@192.168.15.15
chmod +x ~/bin/lore
lore --version      # should answer something like: lore X.Y.Z-nightly+0
lore --help         # confirms the whole CLI loads, not just --version
```

⚠️ **Watch out for PowerShell vs. bash quoting:** if you're testing a remote
`$HOME` via `ssh user@host 'command'` from PowerShell, use **single quotes**
— double quotes make PowerShell expand `$HOME` locally (becomes
`C:\Users\...`) before sending it. For reliable testing, prefer opening an
interactive SSH session.

---

## 10. Cosmetic warnings that can be ignored

- `warning: ... Failed to execute Lore to get revision information, unknown
  version generated: No such file or directory (os error 2)` — `build.rs`
  tries to run `lore` itself (which doesn't exist yet) to embed revision
  metadata; it falls back to generating "unknown version". Nothing breaks;
  the binary just reports its version without a specific revision hash.
- `warning: dropping unsupported crate type 'cdylib' for target ...` —
  expected when building for musl; doesn't affect the `lore`/`loreserver`
  binaries.

---

## 11. Quick checklist for every upstream sync

1. [ ] Check the releases page: is there already a generic ARM64/cortex-a72
       binary? If so, download it and stop here.
2. [ ] `git fetch origin` and review what's changed since the last sync.
3. [ ] Re-confirm §6.1 (`grep '^uuid' lore-server/Cargo.toml`) — if upstream
       fixed it, remove this fork's duplicate.
4. [ ] Build (§7) with no manual `RUSTFLAGS`.
5. [ ] `file` the binary → confirm aarch64 + musl.
6. [ ] `scp` to `~/bin/` on the EON, `chmod +x`, test `--version` and
       `--help`.
7. [ ] If a new patch is needed, also consider opening an upstream PR (the
       project is pre-1.0 and accepts contributions via DCO with no CLA).

---

## 12. References

- Upstream: https://github.com/EpicGames/lore
- This fork: https://github.com/alsimoes/lore-rpi
- Upstream releases: https://github.com/EpicGames/lore/releases
- Server deploy doc:
  https://epicgames.github.io/lore/how-to/deploy-local-lore-server/
- uuid's unstable feature: https://docs.rs/uuid (features section)
- To publish a release of this fork and install/update the binaries on the
  Pi (instead of building and copying manually), see
  [lore-rpi-release.md](lore-rpi-release.md).
