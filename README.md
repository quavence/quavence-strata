# Quavance AI — Local Strata Setup

Run a 125-billion-parameter AI model on your own machine. Private by default:
the model runs locally, nothing is sent to anyone, and the server is reachable
only from the computer it runs on until you deliberately change that.

This repository contains two installers and the guide below. They wrap
[Strata](https://github.com/Niko1221/Strata) (MIT), which does the actual work
of detecting your GPU and building the right engine. What we add is a preflight
check that fails early with a readable reason, a hardened configuration, and a
service so it survives reboots.

---

## What you need

| | |
| --- | --- |
| **GPU** | NVIDIA RTX 20/30/40/50 series, or AMD Radeon RX 7900 XT/XTX, RX 7800 XT, RX 7700 XT, RX 9060 XT, RX 9070/9070 XT, Radeon AI PRO R9700, RX 6800/6900. **12 GB VRAM or more.** Integrated graphics will not work. |
| **Driver** | NVIDIA **580 or newer** (for Pascal cards like Tesla P100/P40: **535 or newer**). AMD: current Adrenalin on Windows, the kernel amdgpu driver on Linux. |
| **RAM** | **32 GB minimum**, 64 GB recommended. Your RAM decides which model size fits. |
| **Disk** | **~80 GB free**, on an SSD if you have one. The first start is much faster from NVMe. |
| **OS** | Windows 10/11, or Linux (Ubuntu 22.04/24.04 and Debian 12/13 are fully automatic). |

Intel Arc works but is an experimental upstream path that builds from source and
needs Docker. The Linux installer detects it and tells you so before starting.

### Which size should I install?

| Your RAM | Install | Why |
| --- | --- | --- |
| 32 GB | `--family coder --model IQ1_M` | made for code, fits 32 GB |
| 48 GB | `--model IQ2_XS` | the larger sizes do not fit |
| **64 GB** | **`--model IQ2_XS`** *(default)* | best balance of speed and quality |
| 96 GB+ | `--model IQ3_S` | slower, a little smarter |

`IQ2_XS` is the default because it is the size most people should run. Roughly
79 tokens/second on an RTX 5070, 52 on an RX 9070 XT.

---

## Install

### Linux

```bash
git clone https://github.com/quavance/quavance-strata.git
cd quavance-strata
chmod +x install-strata.sh
./install-strata.sh --check      # look before you leap: changes nothing
./install-strata.sh
```

### Windows

Open PowerShell in the folder — a normal window, **not** Administrator:

```powershell
.\install-strata.ps1 -Check
.\install-strata.ps1
```

If PowerShell refuses to run the script, allow it for this session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### How long it takes

The model is about **70 GB**. On a 100 Mbit connection that is 1.5–2 hours. The
download resumes, so if it stops, run the same command again.

**Your computer may become slow or stop responding for 1–3 minutes the first
time the model starts.** This is normal: Strata is loading 35–55 GB into RAM and
locking part of it for the GPU. Wait it out. Do not close the window.

### Options

| Flag (Linux) | Flag (Windows) | Meaning |
| --- | --- | --- |
| `--check` | `-Check` | preflight only, install nothing |
| `--model IQ3_S` | `-Model IQ3_S` | pick a different size |
| `--family coder` | `-Family coder` | the code-specialised model |
| `--context 65536` | `-Context 65536` | smaller context uses less RAM |
| `--dir /opt/Strata` | `-Dir C:\Strata` | where Strata is installed |
| `--data-dir /mnt/big` | `-DataDir D:\models` | where the 70 GB goes |
| `--port 8081` | `-Port 8081` | if 8080 is taken |
| `--no-service` | — | skip the systemd service |
| `--no-patch-cuda` | — | never modify CUDA's headers (see below) |
| — | `-AutoStart` | start at logon via a scheduled task |
| `--yes` | `-Yes` | no prompts, for unattended installs |

---

## After it finishes

```
base URL:  http://127.0.0.1:8080/v1
API key:   in .strata-api-key inside the Strata folder
```

Point any OpenAI-compatible app at that base URL and give it the key. Apps that
speak Anthropic's API use `http://127.0.0.1:8080/v1/messages`.

The browser interface at `http://127.0.0.1:8080` has a chat, a live **Monitor**
of the model and your hardware, and an **About** tab with the current settings.

**Linux service:**

```bash
systemctl status strata
systemctl restart strata
journalctl -u strata -f
```

**Check it is alive:**

```bash
curl http://127.0.0.1:8080/health
```

---

## Security and privacy

### What the installer does by default

**Binds to `127.0.0.1` only.** Nothing outside the machine can connect. Not
other computers on your network, not your router, not the internet.

**Generates a 256-bit API key and requires it.** Even on localhost. This matters
more than it sounds: without a key, *any* program on your machine — and any
website you visit, via DNS rebinding — can use your model, read your
conversations, and run up your electricity bill. The key is written to
`.strata-api-key` with permissions that allow only your user account to read it.

**Turns image input off.** When images are enabled the server accepts paths and
URLs and goes and reads them. That is a category of attack surface you do not
need unless you actually want to send pictures to the model. Off removes the
code path entirely. Turn it on deliberately with `./setup.sh --setup --vision yes`.

**Runs as your user, not root.** The systemd unit sets `NoNewPrivileges`,
`PrivateTmp`, and blocks kernel tunables and module loading. The one privilege
it does get is `LimitMEMLOCK=infinity`, which the engine genuinely needs to lock
RAM for the GPU — without it, it will not start.

**Re-checks the configuration afterwards.** Strata's setup rewrites
`strata-<model>.json`, and it has been observed to change the bind address and
to quietly reduce the context based on free RAM. The installer reads the file
back and corrects the host and port if they moved.

### What the installer does not do

- It does not install or update GPU drivers. If yours is too old it tells you and stops.
- It does not change your firewall. Nothing is listening off-machine, so there is nothing to firewall.
- It does not phone home. Neither does Strata. Your prompts never leave the machine.

### Risks you should understand

**Exposing it to the network.** The one change that turns a private tool into a
public one is the bind address. If you need it from another device:

- **Good:** a private mesh VPN (WireGuard, Tailscale, NetBird) and bind to that interface, with the API key.
- **Good:** an SSH tunnel — `ssh -N -L 8080:127.0.0.1:8080 you@the-machine` — nothing is exposed at all.
- **Bad:** `--host 0.0.0.0` on a machine with a public IP.
- **Never:** a tunnel or port forward in front of a server with no API key.

**Tools and agents.** If you connect a coding agent or an MCP server, the model
can run commands and read files with your permissions. A model is not a
trustworthy decision-maker about what it should execute: anything it reads — a
web page, a README, a code comment — can contain instructions aimed at it. Give
agents the narrowest access that does the job, and prefer read-only tools.

**Where the weights come from.** The model files are downloaded from Hugging
Face, built by the Qwen team and quantised by ISTA-DASLab, UkisAI and Unsloth.
That is a normal open-source trust chain, and it is still a trust chain. You are
running 70 GB of binary weights from the internet.

**Resource exhaustion.** Strata locks a large amount of RAM. On a machine that
also does other work, a too-large model will not fail cleanly, it will make
everything slow. Pick the size that fits your RAM from the table above.

**Keep it updated.** `./update.sh` on Linux, `UPDATE.bat` on Windows. Watch
[the repository](https://github.com/Niko1221/Strata) for security releases.
Found a security problem in Strata itself? Report it privately through
[SECURITY.md](https://github.com/Niko1221/Strata/blob/main/SECURITY.md), not a
public issue.

---

## Troubleshooting

| What you see | What it means |
| --- | --- |
| PC freezes on first start | Normal. The model is loading. Wait up to 10 minutes. |
| Download stopped | Run the installer again. It continues where it stopped. |
| `port 8080 is already in use` | Strata is running. Check `curl 127.0.0.1:8080/health`, or use `--port 8081`. |
| Very slow, disk light constant | Not enough free RAM. Close programs or install a smaller size. |
| `the engine stopped unexpectedly` | Same cause: free RAM. |
| `cudaMalloc failed: out of memory` with free VRAM (Windows) | The page file is off or too small. Set a fixed size (e.g. 65536 MB, same initial and maximum) and restart. |
| `prompt ... exceeds the context` | Reinstall with a larger context: `./setup.sh --setup --context 131072`. |
| `NVIDIA driver is too old` | Update to 580 or newer (535 or newer on Pascal P100/P40) and rerun. |
| Service dead after a reboot | `journalctl -u strata -b` will say why. Usually the GPU was not ready yet; the unit sets `StartLimitIntervalSec=0` so it keeps retrying. |
| `error: exception specification is incompatible with that of previous function "cospi"` | glibc 2.41+ against CUDA. The installer patches this automatically — see below. |
| `CUDA 13 does not support this card (compute 6.x)` | CUDA 13 dropped Pascal. A P100 or P40 needs CUDA 12.x. |
| Config changed by itself | You ran `setup.sh --setup`. It rewrites the config, including the bind address and the context. Re-run the installer, or check the JSON by hand. |

Still stuck: [TROUBLESHOOTING.md](https://github.com/Niko1221/Strata/blob/main/docs/TROUBLESHOOTING.md)
upstream, and attach `strata-<model>.log` from the Strata folder to any issue.

---

## The CUDA and glibc conflict

On Ubuntu 25.04, Fedora 42, Arch and anything else with **glibc 2.41 or newer**,
`nvcc` cannot compile anything at all:

```
/usr/include/x86_64-linux-gnu/bits/mathcalls.h(79): error: exception
specification is incompatible with that of previous function "cospi"
```

glibc 2.41 added the C23 functions `sinpi`, `sinpif`, `cospi` and `cospif` and
declared them `noexcept`. CUDA's `crt/math_functions.h` declares the same four
without it. NVIDIA has not shipped a fix, and upgrading is not a way out on
Pascal cards because CUDA 13 dropped them.

The installer detects this and patches the header, keeping a `.bak` beside it.
It changes exactly four lines, adding `noexcept (true)` to each:

```c
extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ double sinpi(double x) noexcept (true);
```

To do it by hand:

```bash
F=$(ls -1 /usr/local/cuda*/targets/x86_64-linux/include/crt/math_functions.h | tail -1)
sudo cp -n "$F" "$F.bak"
sudo sed -i -E 's/^(extern .*\b(sinpi|sinpif|cospi|cospif)\([^)]*\))[[:space:]]*;/\1 noexcept (true);/' "$F"
grep -nE "^extern .*(sinpi|sinpif|cospi|cospif)\(" "$F"
```

All four lines should end in `noexcept (true);`. `sincospi` and `sincospif` are
not affected and must stay as they are.

To undo: `sudo cp "$F.bak" "$F"`. A CUDA reinstall or upgrade undoes the patch,
so rerun the installer afterwards. Pass `--no-patch-cuda` if you would rather
the installer never touched it; the build will then fail with the error above.

---

## Connecting to Quavence DePIN Worker (Tier 3 Rewards)

Once Strata is running locally at `http://127.0.0.1:8080/v1` (with the generated API key saved in `.strata-api-key`), you can connect it directly to the Quavence decentralized compute network to earn mining rewards on **Tier 3 (5.0x reward multiplier)**:

### Option A: Via Quavence-QT Desktop Wallet
1. Open `quavence-qt` and navigate to the **AI Worker** tab.
2. Configure the Inference Provider:
   - **Provider:** `OpenAI-Compatible`
   - **Endpoint:** `http://127.0.0.1:8080/v1`
   - **API Key:** `(paste contents of .strata-api-key)`
   - **Generation Model:** `qwen3.8-flash-next-iq2_xs`
3. Click **Start Worker**. The Quavence Hub will detect the Strata RAM-offload signature and automatically classify your node as **Tier 3 (5.0x reward multiplier)**.

### Option B: Via Headless CLI Worker (`pous-worker`)
Add the following configuration to your worker environment or systemd unit:
```bash
export DEPIN_RUNTIME_PROVIDER="openai_compat"
export DEPIN_RUNTIME_BASE_URL="http://127.0.0.1:8080/v1"
export DEPIN_RUNTIME_API_KEY="$(cat ~/Strata/.strata-api-key)"
export DEPIN_RUNTIME_MODEL="qwen3.8-flash-next-iq2_xs"

./pous-worker-clearnet --node-id=<YOUR_NODE_UUID>
```

Your node will now serve decentralized inference tasks for the Quavence Hub, receiving 85% of each prompt fee directly to your on-chain QVNC wallet address.

---

## Credits

[Strata](https://github.com/Niko1221/Strata) is MIT-licensed, by Niko1221 and
contributors. The model is [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)
by the Qwen team, quantised by [ISTA-DASLab](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF),
UkisAI and Unsloth. Strata uses parts of [llama.cpp / ggml](https://github.com/ggml-org/llama.cpp).

These installers are MIT-licensed too. They install software they did not write;
read them before running them, as you should with any script that asks for sudo.
