# Compilando o Lore para ARM64 (Raspberry Pi 4 / Argon EON)

Runbook para cross-compilar o Lore a partir do código-fonte deste fork
(`lore-rpi`), para rodar num Raspberry Pi 4. Escrito para ser seguido a cada
merge de upstream, por uma pessoa ou por um agente de IA sem o contexto da
investigação original.

**Última verificação:** `main` @ `a0286e9` (pós release `v0.10.0`, ~531 commits
à frente da v0.8.3 onde este runbook começou). As seções marcadas com ⚠️ são
pontos onde o comportamento pode mudar entre merges de upstream — sempre
reavalie-os, não assuma que continuam válidos.

> **Atualização importante:** das quatro incompatibilidades originalmente
> encontradas na v0.8.3, três já foram corrigidas pelo upstream (ver §6). Só
> resta um ajuste de verdade: a feature `zerocopy` faltando no `uuid` do
> `lore-server`. Esse patch já está aplicado neste fork (`lore-rpi`). Este
> documento existe para você não reintroduzir os outros três "consertos" à toa
> quando sincronizar com upstream, e para saber reconfirmar o único que resta.

---

## 1. Por que cross-compilar (e não baixar binário nem compilar no Pi)

Dois fatos que justificam todo o resto deste documento:

- **Não existe binário ARM64 genérico nos releases oficiais do upstream**
  (`EpicGames/lore`). ⚠️ Verifique a página de releases a cada sincronização:
  se passar a existir um asset ARM64 genérico ou `cortex-a72`, boa parte deste
  runbook vira desnecessária — basta baixar.

- **Compilar no próprio Pi é arriscado.** O Pi 4 tem 1.8 GB de RAM e swap
  mínimo. A árvore de dependências do Lore é grande (AWS SDK, gRPC/tonic,
  OpenTelemetry, criptografia). O risco real é estouro de memória na fase de
  *linking* (que carrega tudo de uma vez), não na compilação incremental.
  Também há pouco espaço livre em disco no cartão SD. Cross-compilar no
  desktop e copiar o binário pronto evita os dois problemas.

- **glibc do alvo é antiga.** O Argon EON roda Debian 11 (Bullseye), **glibc
  2.31**. Qualquer binário linkado dinamicamente contra uma glibc mais nova
  falha no destino com erros tipo `version 'GLIBC_2.xx' not found`. A solução
  é compilar **estático contra musl** (target `aarch64-unknown-linux-musl`),
  que elimina totalmente a dependência da glibc do sistema-alvo.

---

## 2. Ambiente de build (host)

- **SO host:** Windows + WSL2, distro **Arch Linux**.
  - Há também uma distro Ubuntu instalada no WSL, mas o toolchain foi montado
    no Arch. Use o Arch: `wsl -d archlinux`.
  - ⚠️ A distro Arch importada no WSL roda como **root** por padrão (prompt
    `[root@...]`) e **não tem `sudo`**. Rode comandos de admin direto, sem
    `sudo` na frente. Se um script tiver `sudo`, remova.
  - ⚠️ O systemd precisa estar habilitado no WSL para o
    `pacman-key`/`gpg-agent` funcionarem (ver seção 4). Confirme com
    `ps -p 1 -o comm=` → deve responder `systemd`.

- **Caminho do repositório:** o clone do Windows aparece em `/mnt/c/...`
  dentro do WSL (ex.: `C:\dev\repos\lore-rpi` = `/mnt/c/dev/repos/lore-rpi`).
  **Sempre trabalhe pelo caminho `/mnt/c/...` dentro do WSL**, nunca tente
  rodar os comandos de build no PowerShell — o Rust nativo do Windows é uma
  instalação separada e NÃO tem o target musl, o zig, nem o cargo-zigbuild.

- **Alvo (destino):** Argon EON, IP `192.168.15.15`, usuário `alsimoes`,
  Debian 11 ARM64, glibc 2.31, CPU Cortex-A72.

---

## 3. Toolchain necessário (instalar uma vez)

Dentro do Arch WSL, como root:

```bash
pacman -Syu --noconfirm
pacman -S --needed --noconfirm base-devel git openssh rustup aarch64-linux-gnu-gcc zig

rustup default stable
rustup target add aarch64-unknown-linux-musl
cargo install cargo-zigbuild
```

Confirme:

```bash
rustc --version
cargo --version
zig version
cargo zigbuild --version
ssh -V
```

Notas:
- `cargo-zigbuild` usa o Zig como linker/cross-toolchain universal. É o que
  torna o build musl-ARM64 viável sem montar um cross-linker musl manualmente
  (que não está nos repos oficiais do Arch).
- O `aarch64-linux-gnu-gcc` vem do repositório oficial `extra` do Arch (não
  precisa de AUR).

---

## 4. Problemas de ambiente conhecidos (pacman/keyring)

Se a instalação do toolchain falhar, quase sempre é um destes:

**Mirror lento** (`error: failed retrieving file ... Operation too slow`):
troque o mirrorlist por mirrors brasileiros e force re-sync com `-Syy`:

```bash
cat > /etc/pacman.d/mirrorlist << 'EOF'
Server = https://archlinux.c3sl.ufpr.br/$repo/os/$arch
Server = https://br.mirrors.cicku.me/archlinux/$repo/os/$arch
Server = https://mirror.ufscar.br/archlinux/$repo/os/$arch
EOF
pacman -Syy
```

**Keyring desatualizado** (`signature ... is unknown trust` / `invalid or
corrupted package (PGP signature)`): NÃO é corrupção de download — é o
`archlinux-keyring` velho demais. Reconstrua o keyring. Isto exige o systemd
ativo (senão dá `agent_genkey failed: No such file or directory`):

```bash
# 1) garantir systemd no WSL
cat > /etc/wsl.conf << 'EOF'
[boot]
systemd=true
EOF
# 2) no PowerShell: wsl --shutdown   e reabrir:  wsl -d archlinux
# 3) confirmar: ps -p 1 -o comm=   →  systemd
# 4) reconstruir keyring:
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring --noconfirm
```

---

## 5. Sincronizar com upstream antes de compilar

Este fork (`lore-rpi`) segue o `main` de `EpicGames/lore`. Antes de compilar,
sincronize e reconfirme o único ajuste que resta (§6):

```bash
cd /mnt/c/dev/repos/lore-rpi
git fetch origin
git status   # confirme que está limpo antes de avançar
```

⚠️ Diferente do runbook original (que fixava numa tag de release estável),
este fork agora acompanha o `main` de propósito — é o que o mantemos
sincronizado para. Ainda assim, depois de um `git merge`/`rebase` grande vindo
do upstream, rode um build local antes de promover para o Pi.

---

## 6. Ajuste que ainda é necessário (reavaliar a cada sync ⚠️)

Das quatro incompatibilidades encontradas originalmente na v0.8.3, três já
foram corrigidas pelo próprio upstream entre a v0.8.3 e a v0.10.0:

- **CPU hardcoded em `lore-base/build.rs`:** o `-mcpu=neoverse-512tvb` que
  antes era forçado incondicionalmente em qualquer build Linux ARM64 agora só
  é aplicado quando a feature `neoverse-512tvb` do `lore-base` é ligada
  explicitamente (`--features lore-base/neoverse-512tvb`, ver
  `.cargo/neoverse-512tvb.toml`). Um build normal para `aarch64-unknown-linux-*`
  não recebe mais nenhum `-mcpu` que assuma SVE — o Cortex-A72 do Pi 4 já
  compila sem patch.
- **`--cfg tokio_unstable`:** já vem embutido no `[build].rustflags` de
  `.cargo/config.toml`, aplicado a qualquer target que não tenha uma tabela
  `[target.*]` própria (como é o caso de `aarch64-unknown-linux-musl`).
- **`--cfg uuid_unstable`:** idem — já está no mesmo `[build].rustflags`.

Ou seja: **não é mais necessário passar `RUSTFLAGS` manualmente** nem editar
`build.rs` para compilar para o Pi. Só resta:

### 6.1 — Feature `zerocopy` faltando no uuid (lore-server/Cargo.toml)

**Sintoma:** erros E0277 `the trait bound 'Uuid: IntoBytes' is not satisfied`
(e `FromBytes`, `Immutable`, `TryFromBytes`, `FromZeros`) em
`lore-server/src/protocol/replication_store/header.rs`.

**Causa:** o workspace declara `uuid` com `default-features = false`. Crates
que usam derives do zerocopy sobre `Uuid` precisam ativar a feature
`zerocopy` explicitamente. `lore-base`, `lore-revision` e `lore-storage` já
fazem isso; o `lore-server` não fazia.

**Status neste fork:** já aplicado —
`lore-server/Cargo.toml` tem `uuid = { workspace = true, features =
["zerocopy"] }`.

**Como saber se ainda é necessário depois de um sync com upstream:**
```bash
grep -n "^uuid" lore-server/Cargo.toml
```
Se já vier com `features = ["zerocopy"]`, não faça nada — o upstream pode ter
corrigido isso também, ou seu merge já trouxe o patch deste fork.

### 6.2 — Tuning opcional de CPU para o Cortex-A72

O upstream já estabeleceu o padrão para isso (feature `neoverse-512tvb` +
`.cargo/neoverse-512tvb.toml`, ver §3 acima). Se quiser o mesmo ganho de
performance para o Cortex-A72, o caminho é espelhar esse padrão: uma feature
`cortex-a72` em `lore-base/Cargo.toml`, o `-mcpu` correspondente em
`lore-base/build.rs` (gated por `CARGO_FEATURE_CORTEX_A72`), e um
`.cargo/cortex-a72.toml` com `rustflags = ["-C", "target-cpu=cortex-a72"]`.

⚠️ **Isto ainda não foi feito neste fork** porque o valor exato aceito pelo
`-mcpu` depende de qual C toolchain compila o `rpmalloc.c` do `lore-base` em
tempo de build — `cc`/`gcc` reais aceitam `cortex-a72` (hífen), mas o
`cargo-zigbuild` troca o `CC` por um wrapper do `zig`, e o `zig` tem histórico
de exigir `cortex_a72` (underscore) nesse contexto (todo texto depois do
primeiro hífen é lido como modificador de feature). Não implemente às cegas —
teste os dois no seu toolchain (`zig targets | grep -i cortex`) antes de
fixar um valor. Sem esse ajuste, o build funciona normalmente; só não tem a
tunagem específica de CPU (equivalente ao "portable baseline" que o próprio
upstream usa como default para `aarch64-unknown-linux-gnu`).

---

## 7. Compilar

```bash
cd /mnt/c/dev/repos/lore-rpi

# CLI cliente (para rodar no Pi como cliente):
cargo zigbuild --release --target aarch64-unknown-linux-musl --bin lore

# Servidor (para hospedar uma instância no Pi):
cargo zigbuild --release --target aarch64-unknown-linux-musl --bin loreserver
```

Não é mais necessário passar `RUSTFLAGS` (ver §6) — os cfgs de que o
`loreserver` precisa já vêm do `.cargo/config.toml` do repositório.

Notas:
- A primeira compilação leva ~10-12 min (compila toda a árvore de
  dependências).
- Se precisar garantir um estado limpo após muitas tentativas, `cargo clean`
  primeiro (ao custo de recompilar tudo).
- Os binários saem em
  `target/aarch64-unknown-linux-musl/release/{lore,loreserver}`. Repare no
  `musl` no caminho — é diferente do diretório `gnu`.

---

## 8. Verificar o binário antes de copiar

```bash
file target/aarch64-unknown-linux-musl/release/lore
```

Esperado: `ELF 64-bit LSB ... ARM aarch64 ... statically linked`. Confirmar
"aarch64" e idealmente "statically linked" (musl) evita descobrir
incompatibilidade só depois de copiar para o Pi.

---

## 9. Copiar para o Argon EON e instalar

Pré-requisito no Pi: o diretório `~/bin` precisa existir e estar no PATH. ⚠️ O
shell de login do `alsimoes` é `sh`/dash (não bash), então a config de PATH
vive no `~/.profile` (que já contém o bloco condicional padrão do Debian: `if
[ -d "$HOME/bin" ]; then PATH="$HOME/bin:$PATH"; fi`). Garanta que `~/bin`
existe:

```bash
ssh alsimoes@192.168.15.15 'mkdir -p ~/bin'
```

Copiar (rode de dentro do WSL Arch, que tem o binário; vai pedir senha — sem
chave SSH configurada, é interativo e normal):

```bash
scp target/aarch64-unknown-linux-musl/release/lore alsimoes@192.168.15.15:~/bin/lore
# e/ou:
scp target/aarch64-unknown-linux-musl/release/loreserver alsimoes@192.168.15.15:~/bin/loreserver
```

Tornar executável e testar (sessão interativa nova, para o PATH do
`.profile` valer):

```bash
ssh alsimoes@192.168.15.15
chmod +x ~/bin/lore
lore --version      # deve responder algo como: lore X.Y.Z-nightly+0
lore --help         # confirma que a CLI inteira carrega, não só o --version
```

⚠️ **Cuidado com quoting PowerShell vs. bash:** se for testar `$HOME` remoto
via `ssh user@host 'comando'` a partir do PowerShell, use **aspas simples** —
aspas duplas fazem o PowerShell expandir `$HOME` localmente (vira
`C:\Users\...`) antes de enviar. Para testes confiáveis, prefira abrir uma
sessão SSH interativa.

---

## 10. Avisos cosméticos que podem ser ignorados

- `warning: ... Failed to execute Lore to get revision information, unknown
  version generated: No such file or directory (os error 2)` — o `build.rs`
  tenta rodar o próprio `lore` (que ainda não existe) para embutir metadado
  de revisão; cai num fallback que gera "unknown version". Não quebra nada; o
  binário só reporta a versão sem hash de revisão específico.
- `warning: dropping unsupported crate type 'cdylib' for target ...` —
  esperado ao compilar para musl; não afeta os binários `lore`/`loreserver`.

---

## 11. Checklist rápido para cada sync com upstream

1. [ ] Checar a página de releases: já existe binário ARM64 genérico/cortex-
       a72? Se sim, baixar e parar aqui.
2. [ ] `git fetch origin` e revisar o que mudou desde o último sync.
3. [ ] Reconfirmar §6.1 (`grep '^uuid' lore-server/Cargo.toml`) — se o
       upstream corrigiu isso, remover a duplicata deste fork.
4. [ ] Compilar (§7) sem `RUSTFLAGS` manual.
5. [ ] `file` no binário → confirmar aarch64 + musl.
6. [ ] `scp` para `~/bin/` no EON, `chmod +x`, testar `--version` e `--help`.
7. [ ] Se algum patch novo for necessário, considerar também abrir PR
       upstream (o projeto é pré-1.0 e aceita contribuição via DCO sem CLA).

---

## 12. Referências

- Upstream: https://github.com/EpicGames/lore
- Este fork: https://github.com/alsimoes/lore-rpi
- Releases upstream: https://github.com/EpicGames/lore/releases
- Doc de deploy do servidor:
  https://epicgames.github.io/lore/how-to/deploy-local-lore-server/
- Feature instável do uuid: https://docs.rs/uuid (seção de features)
