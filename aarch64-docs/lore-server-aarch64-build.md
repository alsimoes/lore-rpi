# Compilando o `lore-server` para aarch64 (Raspberry Pi 4)

Guia de referência para cross-compilar o binário `loreserver` deste fork
(`lore-rpi`) para um Raspberry Pi 4, a cada sync com o upstream
(`EpicGames/lore`). Escrito para ser seguido tanto por uma pessoa quanto por
um agente de IA. Complementa [lore-aarch64-build.md](lore-aarch64-build.md),
que cobre o ambiente de build e a CLI `lore`.

> **Resumo em uma frase:** o `loreserver` compila para
> `aarch64-unknown-linux-musl` via `cargo-zigbuild`, sem nenhum `RUSTFLAGS`
> manual — só é preciso a feature `zerocopy` no `uuid` de
> `lore-server/Cargo.toml`, já aplicada neste fork.

---

## 1. Ambiente

### Alvo (target)
| Item | Valor |
|------|-------|
| Hardware | Raspberry Pi 4 (Argon EON NAS) |
| CPU | ARM Cortex-A72 (ARMv8-A, **sem** SVE) |
| Arquitetura | ARM64 / aarch64 |
| SO | Debian 11 (Bullseye) |
| glibc | 2.31 |

> **Por que `musl` e não `gnu`?** O alvo roda glibc 2.31. Linkar com
> `aarch64-unknown-linux-gnu` no host amarraria o binário à glibc do host
> (mais nova), causando erros `GLIBC_2.3x not found` no Pi. Usar
> `aarch64-unknown-linux-musl` produz um binário estático/independente da
> glibc, que roda em qualquer userland aarch64. É a escolha mais robusta para
> um NAS com SO antigo.

### Host de build
| Ferramenta | Observação |
|------------|------------|
| SO do host | WSL2 + Arch Linux (qualquer Linux x86_64 serve) |
| `cargo-zigbuild` | wrapper que usa o `zig` como linker cross |
| `zig` | fornece o toolchain C/cross-linking |
| Rust target | `aarch64-unknown-linux-musl` (`rustup target add aarch64-unknown-linux-musl`) |

Checagem rápida do host antes de compilar:

```bash
rustc --version
cargo zigbuild --version
zig version
rustup target list --installed | grep aarch64-unknown-linux-musl
```

---

## 2. Comando de build (a fonte da verdade)

```bash
cd /mnt/c/dev/repos/lore-rpi
cargo zigbuild --release --target aarch64-unknown-linux-musl --bin loreserver
```

O binário sai em:

```
target/aarch64-unknown-linux-musl/release/loreserver
```

⚠️ Nenhum `RUSTFLAGS` é necessário. Os `--cfg tokio_unstable` e `--cfg
uuid_unstable` que o `loreserver` exige já estão versionados em
`.cargo/config.toml` (seção `[build]`), que se aplica automaticamente a
qualquer target — como `aarch64-unknown-linux-musl` — que não tenha sua
própria tabela `[target.*]` nesse arquivo. Isso é diferente do estado da
v0.8.3, quando esses cfgs precisavam ser passados manualmente (ver histórico
deste doc no git se quiser os detalhes de por que).

---

## 3. O único ajuste que ainda é necessário

### Feature `zerocopy` do `uuid` em `lore-server/Cargo.toml`

| Campo | Detalhe |
|-------|---------|
| Arquivo | `lore-server/Cargo.toml` |
| Original (upstream) | `uuid = { workspace = true }` |
| Corrigido (neste fork) | `uuid = { workspace = true, features = ["zerocopy"] }` |
| Tipo | Edição de Cargo.toml |
| Status | **Já aplicado** neste fork |

**Causa-raiz:** `ReplicationHeader`
(`lore-server/src/protocol/replication_store/header.rs`) deriva traits do
zerocopy sobre um campo `Uuid`. Isso exige que a crate `uuid` tenha a feature
`zerocopy` ligada. As crates `lore-base`, `lore-revision` e `lore-storage` já
fazem isso; só o `lore-server` estava com a inconsistência.

**Por que o cfg sozinho (`uuid_unstable`) não bastava:** ligar a *feature*
`zerocopy` só puxa a *dependência*. Os `impl IntoBytes/FromBytes/Immutable for
Uuid` no crate `uuid` ficam atrás de **dois** condicionais em conjunto —
`all(uuid_unstable, feature = "zerocopy")`. O `--cfg uuid_unstable` já vinha
resolvido no `.cargo/config.toml` do workspace; faltava exatamente a feature
no `Cargo.toml` do `lore-server`. Ver
[uuid-rs/uuid#588](https://github.com/uuid-rs/uuid/issues/588).

**Status upstream:** ainda é uma inconsistência real do `EpicGames/lore`
(as outras três crates do workspace já fazem certo) — candidato a PR.

### Reconfirmar depois de um sync com upstream

```bash
grep -n '^uuid' lore-server/Cargo.toml
# compare com as crates que já acertam:
grep -n '^uuid' lore-base/Cargo.toml lore-revision/Cargo.toml lore-storage/Cargo.toml
```

Se o `lore-server` já vier com `features = ["zerocopy"]` (por exemplo, porque
o upstream aceitou o PR, ou porque o merge trouxe o patch deste fork sem
conflito), não faça nada.

---

## 4. Ajustes que ficaram obsoletos (histórico — não reaplicar)

Estes dois existiam quando este runbook foi escrito contra a v0.8.3. Entre a
v0.8.3 e a v0.10.0 o upstream corrigiu ambos. Documentados aqui só para você
não os reintroduzir achando que "sempre foi assim":

- **`-mcpu=neoverse-512tvb` hardcoded em `lore-base/build.rs`:** virou
  opt-in, atrás da feature `neoverse-512tvb` do `lore-base`. Um build normal
  para aarch64 não recebe mais esse `-mcpu`, então não quebra em CPUs
  sem SVE-512 como o Cortex-A72 — sem precisar de nenhum patch.
- **`--cfg tokio_unstable` / `--cfg uuid_unstable` via `RUSTFLAGS` manual:**
  os dois já estão versionados no `[build].rustflags` de
  `.cargo/config.toml` do repositório.

Se depois de um sync futuro o build voltar a falhar com `unknown CPU` ou com
`unresolved import` gated por `cfg(tokio_unstable)`/`cfg(uuid_unstable)`,
é sinal de que o upstream reestruturou esse mecanismo de novo — trate como um
problema novo, não reaplique os patches antigos às cegas.

---

## 5. Verificação no destino (Pi 4)

Após copiar o binário para o Pi:

```bash
file ./loreserver
# Esperado: ELF 64-bit LSB ... ARM aarch64 ...  (estático, se musl)

./loreserver --version    # ou --help
```

Smoke-test mínimo recomendado: subir o serviço com uma config local
(`config/local.toml`) e confirmar que ele inicia e responde ao health check
antes de promover a produção.

---

## 6. Invariantes e armadilhas

- **Formato on-the-wire (CRÍTICO).** O `ReplicationHeader` faz parte do
  protocolo de replicação; seu layout de bytes **não pode mudar**. A
  abordagem escolhida (ligar `uuid_unstable`/feature `zerocopy` e usar o impl
  real do `uuid`) preserva o layout byte-a-byte e é idêntica ao build do
  upstream. **Evite** trocar `Uuid` por `[u8; 16]` no header como contorno —
  funciona, mas exige editar todas as bordas que chamam
  `.as_hyphenated()`/`.to_string()`/`Uuid::new_v4()` nos serviços de
  replicação e testes, e introduz risco de divergência de formato. Só
  considere isso se o `uuid_unstable` for removido upstream sem substituto.
- **`cargo-zigbuild` é necessário** (não `cargo build` puro) para o
  cross-linking com musl via `zig`.
- Se quiser tunar especificamente para o Cortex-A72 (em vez do baseline
  portável que o upstream usa por padrão para `aarch64-unknown-linux-gnu`),
  ver a nota sobre o `-mcpu` em
  [lore-aarch64-build.md § 6.2](lore-aarch64-build.md#62--tuning-opcional-de-cpu-para-o-cortex-a72)
  — o valor certo depende do C toolchain (`zig cc` via zigbuild exige sintaxe
  diferente de um `gcc` real) e precisa ser validado empiricamente antes de
  fixar.

---

## 7. Itens candidatos a PR upstream

1. `lore-server/Cargo.toml`: falta `features = ["zerocopy"]` no `uuid`
   (inconsistente com `lore-base`, `lore-revision` e `lore-storage`, que já
   fazem isso).
