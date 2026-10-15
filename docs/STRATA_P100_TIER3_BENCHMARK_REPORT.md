---
tags:
  - ai
  - strata
  - hardware
  - inference
  - homelab
aliases:
date: 2026-10-15
status: active
host: openclaw
---

# Openclaw Strata Worker — Hardware, Runtime and Configuration Report

**Report date:** 15 October 2026 · **Host:** `openclaw`

> [!info] What this note covers
> The current Strata inference setup on `openclaw`, how to change it safely, and what must be
> verified before claiming Tier 3 (5.0× reward multiplier) eligibility.

> [!warning] Tier 3 is NOT verified
> A running worker and successful inference do not prove eligibility. Do not promise a 5.0×
> multiplier until the official Strata operator requirements have been checked. See
> [[#7 Tier 3 — 5.0× reward multiplier]].

## 📋 At a glance

| | |
|---|---|
| CPU | AMD Ryzen 9 5950X — 16 cores / 32 threads |
| RAM | 64 GB DDR4-3200 (2 × 32 GB) |
| GPU | NVIDIA Tesla P100 PCIe — 16 GB HBM2 |
| OS | Debian GNU/Linux 13.7 (trixie) |
| Driver / CUDA | `580.178.04` · CUDA 13.0 reported by `nvidia-smi` |
| Engine build | CUDA 12.9 — `/home/user/Strata/engine-cuda12/strata` |
| Model | Qwen3.8-Flash-Next GSQ-RCO, `IQ2_XS` |
| Context | 65,536 tokens, `--kv k8v4`, `--kv-resident 32768` |
| Config file | `/home/user/Strata/strata-iq2_xs.json` |
| Service | `strata.service` — enabled and active |
| API | `http://127.0.0.1:8080/v1` (loopback) |

**Contents:** [[#1 Hardware configuration]] · [[#2 Model and quantization]] ·
[[#3 Active runtime configuration]] · [[#4 How to change the configuration safely]] ·
[[#5 systemd and reboot persistence]] · [[#6 Measured performance and memory observations]] ·
[[#7 Tier 3 — 5.0× reward multiplier]] · [[#8 Copy-ready summary]]

---

## 1 Hardware configuration

| Component | Details |
|---|---|
| CPU | AMD Ryzen 9 5950X, 16 cores / 32 threads |
| System RAM | 64 GB DDR4, 2 × 32 GB, configured at 3200 MT/s |
| Theoretical system RAM bandwidth | Approximately 51.2 GB/s for dual-channel DDR4-3200 |
| GPU | NVIDIA Tesla P100 PCIe, 16 GB HBM2 |
| Theoretical GPU memory bandwidth | Approximately 549 GB/s |
| Motherboard | ASRock B450M-HDV R4.0 |
| BIOS | P10.43, dated 2025-06-24 |
| Operating system | Debian GNU/Linux 13.7 (trixie) |
| Kernel | Previously recorded as `6.12.96+deb13-amd64`; verify current version before publishing |
| NVIDIA driver | `580.178.04` |
| CUDA driver capability | CUDA 13.0 reported by `nvidia-smi` |
| Strata engine build | CUDA 12.9 build at `/home/user/Strata/engine-cuda12/strata` |

The bandwidth figures are theoretical peak estimates, not measured sustained bandwidth on this
worker. The P100 is the compute GPU; its VRAM availability varies with the model, expert cache,
KV cache and other GPU allocations.

### Verify current hardware details

```bash
uname -r
free -h
nvidia-smi
sudo dmidecode -t memory \
  | grep -E 'Size:|Speed:|Configured Memory Speed:|Locator:|Type:'
```

---
## 2 Model and quantization

- **Model:** Qwen3.8-Flash-Next, GSQ-RCO variant
- **Model quantization:** `IQ2_XS`
- **Model name in API configuration:** `qwen3.8-flash-next-iq2_xs`
- **Configured context limit:** 65,536 tokens
- **KV-cache format:** `k8v4`
- **KV residency:** 32,768 cells per QSA layer in VRAM, with the remaining K/V data managed in pinned RAM as described by the engine
- **Speculative decoding:** `--spec 4 --spec-min-p 0.5`
- **Expert cache:** `--expert-cache auto`
- **Prefill:** `--prefill auto:32768`
- **MTP helper:** `/home/user/Strata-data/mtp/rt`

### Model files and paths

| Purpose | Path |
|---|---|
| Prepared model pack | `/home/user/Strata-data/packs/iq2_xs` |
| Main GGUF shard | `/home/user/Strata-data/models/IQ2_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf` |
| PLE GGUF shard | `/home/user/Strata-data/models/IQ2_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf` |
| Expert profile | `/home/user/Strata/data/expert-profile.bin` |
| MTP helper | `/home/user/Strata-data/mtp/rt` |
| Tokenizer | `/home/user/Strata-data/packs/iq2_xs/tokenizer` |
| Active JSON config | `/home/user/Strata/strata-iq2_xs.json` |
| Strata log | `/home/user/Strata/strata-iq2_xs.log` |

> [!warning] Keep all referenced files in place
> The main and PLE GGUF files are both referenced by the active engine command. Moving or
> renaming any of these paths breaks the service at next restart.

### What `k8v4` means

The previous configuration used `--kv int8`; it was changed to `--kv k8v4`.

- **K:** INT8 keys.
- **V:** rotated Q4_0 values.
- **Reported KV-cache footprint:** 816 bytes per cell, versus 1,056 bytes per cell for INT8, according to this engine's help output. This is approximately 22.7% less memory per cell.
- **Trade-off:** KV-cache representation and precision differ from INT8. Actual speed and output quality must be measured.

This setting changes the KV-cache representation, not the IQ2_XS model-weight quantization.

---

## 3 Active runtime configuration

The active configuration file is:

```text
/home/user/Strata/strata-iq2_xs.json
```

Verbatim contents of the active JSON, as read on 2026-10-15:

```json
{
  "exe": "/home/user/Strata/engine-cuda12/strata",
  "args": [
    "--pack",
    "/home/user/Strata-data/packs/iq2_xs",
    "--native",
    "/home/user/Strata-data/models/IQ2_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf",
    "--ple-gguf",
    "/home/user/Strata-data/models/IQ2_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf",
    "--expert-profile",
    "/home/user/Strata/data/expert-profile.bin",
    "--expert-cache",
    "auto",
    "--prefill",
    "auto:32768",
    "--spec",
    "4",
    "--spec-min-p",
    "0.5",
    "--mtp",
    "/home/user/Strata-data/mtp/rt",
    "--max-context",
    "65536",
    "--kv",
    "k8v4",
    "--kv-resident",
    "32768"
  ],
  "cwd": "/home/user/Strata",
  "tokenizer": "/home/user/Strata-data/packs/iq2_xs/tokenizer",
  "model_name": "qwen3.8-flash-next-iq2_xs",
  "log": "/home/user/Strata/strata-iq2_xs.log",
  "lib_dirs": [
    "/usr/local/cuda-12.9/bin",
    "/usr/local/cuda-12.9/lib64"
  ],
  "port": 8080,
  "cuda": 12,
  "gpu": 0,
  "gpus_asked": true,
  "host": "127.0.0.1"
}
```

The same settings, written as a single engine command line:

```bash
/home/user/Strata/engine-cuda12/strata \
  --serve \
  --pack /home/user/Strata-data/packs/iq2_xs \
  --native /home/user/Strata-data/models/IQ2_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf \
  --ple-gguf /home/user/Strata-data/models/IQ2_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf \
  --expert-profile /home/user/Strata/data/expert-profile.bin \
  --expert-cache auto \
  --prefill auto:32768 \
  --spec 4 \
  --spec-min-p 0.5 \
  --mtp /home/user/Strata-data/mtp/rt \
  --max-context 65536 \
  --kv k8v4 \
  --kv-resident 32768
```

### Important flags

| Flag | Current value | Purpose |
|---|---|---|
| `--pack` | `.../packs/iq2_xs` | Prepared model pack |
| `--native` | Main GGUF shard | Main model weights |
| `--ple-gguf` | Second GGUF shard | PLE model data |
| `--expert-profile` | `.../expert-profile.bin` | Expert placement/profile data |
| `--expert-cache` | `auto` | Automatic expert-cache behavior |
| `--prefill` | `auto:32768` | Automatic prompt-prefill tuning, with an explicit `32768` parameter. Earlier drafts of this note recorded this as plain `auto` — that was wrong. |
| `--spec` | `4` | Speculative decoding configuration |
| `--spec-min-p` | `0.5` | Speculative decoding threshold parameter |
| `--mtp` | `.../mtp/rt` | MTP helper data |
| `--max-context` | `65536` | Maximum configured context |
| `--kv` | `k8v4` | Hybrid INT8 K / rotated Q4_0 V cache |
| `--kv-resident` | `32768` | KV cells kept resident in VRAM per QSA layer |

### Other fields in the JSON configuration

| Field | Value |
|---|---|
| `exe` | Engine executable path |
| `cwd` | `/home/user/Strata` |
| `tokenizer` | Prepared tokenizer path |
| `model_name` | `qwen3.8-flash-next-iq2_xs` |
| `log` | `/home/user/Strata/strata-iq2_xs.log` |
| `lib_dirs` | `/usr/local/cuda-12.9/bin`, `/usr/local/cuda-12.9/lib64` |
| `port` | `8080` |
| `cuda` | `12` |
| `gpu` | `0` |
| `gpus_asked` | `true` |
| `host` | `127.0.0.1` |

### The Python server wrapper

The Python server wraps the engine and was observed launching with:

```text
/home/user/Strata/.venv/bin/python
/home/user/Strata/serve/server.py
--engine strata
--config /home/user/Strata/strata-iq2_xs.json
--port 8080
--open
```

The server announced its API at `http://127.0.0.1:8080/v1`.

> [!warning] Loopback address
> `127.0.0.1` is a loopback address intended for local clients. Verify the actual listening
> address before assuming it is reachable from other machines.

---
## 4 How to change the configuration safely

> [!tip] Edit by key, never by position
> Use the key-based edit pattern. Positional editing (line-number `sed`) is what corrupted
> `--vram-reserve-mib` on the other Strata box. See [[Strata-context-and-OpenWebUI-tuning]].

### Step 1 — Back up the current JSON

```bash
cd /home/user/Strata

cp -a strata-iq2_xs.json \
  "strata-iq2_xs.json.bak-$(date +%Y%m%d-%H%M%S)"
```

### Step 2 — Inspect the current settings

```bash
python3 -m json.tool /home/user/Strata/strata-iq2_xs.json
```

### Step 3 — Edit a setting

```bash
nano /home/user/Strata/strata-iq2_xs.json
```

For example, to change the KV cache from `k8v4` back to `int8`, find:

```json
"--kv",
"k8v4",
```

and change it to:

```json
"--kv",
"int8",
```

Save in nano with `Ctrl+O`, press Enter, and exit with `Ctrl+X`.

> [!warning] Do not change it just for the sake of changing it
> The current `k8v4` setting is active; benchmark before deciding whether to revert.

### Step 4 — Validate the JSON before restarting

```bash
python3 -m json.tool \
  /home/user/Strata/strata-iq2_xs.json >/dev/null \
  && echo "JSON valid"
```

Only restart if validation succeeds.

### Step 5 — Restart and check the service

```bash
sudo systemctl restart strata.service

systemctl is-active strata.service
journalctl -u strata.service -n 50 --no-pager
nvidia-smi
```

Restarting interrupts API requests and reloads the model. Wait for Strata to finish loading before testing.

### Verify the running process

```bash
systemctl show strata.service -p ExecStart
ps -eo pid,args | grep '[s]trata --serve'
```

### Roll back

Use the exact backup filename you created:

```bash
cp -a /home/user/Strata/strata-iq2_xs.json.bak-YYYYMMDD-HHMMSS \
  /home/user/Strata/strata-iq2_xs.json

python3 -m json.tool \
  /home/user/Strata/strata-iq2_xs.json >/dev/null \
  && sudo systemctl restart strata.service
```

Replace the example backup filename with the actual one. Inspect the backup before restoring it.

---

## 5 systemd and reboot persistence

The service was confirmed enabled and active.

- **Unit:** `/etc/systemd/system/strata.service`
- **Service name:** `strata.service`
- **Boot startup:** enabled
- **Status at last check:** active (running)
- **Configuration loaded:** `/home/user/Strata/strata-iq2_xs.json`

Useful commands:

```bash
# Check automatic startup
systemctl is-enabled strata.service

# Check current state
systemctl is-active strata.service

# Start, stop, or restart
sudo systemctl start strata.service
sudo systemctl stop strata.service
sudo systemctl restart strata.service

# Follow live logs
journalctl -fu strata.service

# Inspect this boot's service logs
journalctl -b -u strata.service --no-pager
```

Because the unit is enabled, systemd attempts to start Strata at boot. Successful startup still depends on the GPU driver, model files, storage and sufficient system resources being available.

---

## 6 Measured performance and memory observations

These figures are taken from the supplied logs and are workload-specific, not a standardized benchmark.

| Metric | Observed value |
|---|---:|
| Generation rate before changing KV format | Approximately 54–56 tokens/sec |
| Generation rate after changing to `k8v4` | Approximately 46–56 tokens/sec in supplied samples |
| Long generation sample | 1,156 generated tokens at 55.9 tokens/sec |
| Recent prompt-processing samples | Approximately 119–234 tokens/sec |
| Expert-cache hit rate in supplied samples | Variable; approximately 77.5–97.1%, with one larger sample at 88.6% |
| GPU temperature in snapshot | 35°C |
| GPU power in snapshot | Approximately 31 W |
| Latest supplied VRAM snapshot | 15,707 MiB used, 563 MiB free |

The engine reported 32,768 of 65,536 KV cells per QSA layer resident in VRAM and approximately 0.60 GiB of pinned RAM for K/V data. A high KV-streaming hit rate means most logged block reads were served from VRAM; it does not mean the entire cache is in VRAM.

> [!caution] No reliable speed delta yet
> The earlier low-memory snapshot immediately after restart did not persist: the later
> `nvidia-smi` snapshot showed the GPU close to full again. The current samples do not establish
> a reliable speed improvement or regression from `k8v4`.

For a useful comparison, run repeated tests with the same model, prompt, output length, context conditions and workload. Record prompt processing and generation speed separately.

---
## 7 Tier 3 — 5.0× reward multiplier

> [!warning] Eligibility is not verified
> A running worker and successful inference do not, by themselves, prove eligibility.

Before claiming the multiplier, obtain the current official rules from the Strata operator and confirm:

1. **Hardware eligibility:** whether the Tesla P100 and 64 GB system RAM are accepted.
2. **Model eligibility:** whether IQ2_XS and this exact GSQ-RCO model variant qualify.
3. **Runtime requirements:** whether the CUDA engine, `k8v4`, 65,536-token context and speculative-decoding settings meet the requirements.
4. **Performance criteria:** any minimum throughput, successful-job rate, uptime or benchmark thresholds.
5. **Worker registration:** required registration, identity, verification and online duration.
6. **Reward conditions:** whether the multiplier is conditional, capped, time-limited or subject to additional network requirements.

> [!warning] Do not tune flags to chase a multiplier
> Keep a copy of the official announcement or eligibility page and verify every requirement
> against it before changing anything.

---

## 8 Copy-ready summary

**Strata worker `openclaw`:** AMD Ryzen 9 5950X (16 cores / 32 threads), 64 GB DDR4-3200 (2 × 32 GB), NVIDIA Tesla P100 PCIe 16 GB HBM2, Debian 13.7, NVIDIA driver 580.178.04, CUDA 12.9 Strata engine build. The worker runs Qwen3.8-Flash-Next GSQ-RCO in IQ2_XS, with a 65,536-token configured context, `--kv k8v4`, `--kv-resident 32768`, `--expert-cache auto`, `--prefill auto:32768`, `--spec 4`, and `--spec-min-p 0.5`. The active JSON config is `/home/user/Strata/strata-iq2_xs.json`. `strata.service` is enabled and active, so systemd attempts to start it at boot. Observed generation samples are approximately 46–56 tokens/sec; these are not standardized benchmark results. Tier 3 / 5.0× reward eligibility remains unverified pending official operator requirements.

---

## Related notes

- [[OpenClaw-Model-Config]] — current fleet model/context config
- [[services-overview]] — services running on the homelab
- [[Proxmox-Nodes]] — where this worker sits in the fleet
- [[Strata-context-and-OpenWebUI-tuning]] — `k8v4` and long-context tuning on the other Strata box
