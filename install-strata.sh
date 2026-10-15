#!/usr/bin/env bash
# =============================================================================
#  Quavance AI — Strata installer (Linux)
#
#  Installs the Strata inference engine and the Qwen3.8-Flash-Next model,
#  hardened by default: localhost-only, API key required, images disabled.
#
#  This is a WRAPPER around Strata's own ./setup.sh (which already detects
#  NVIDIA and AMD and builds the right engine). It adds:
#    - a preflight check that fails early with a readable reason
#    - a generated API key, stored 0600, never printed into a log
#    - a localhost bind that is re-asserted after setup, because setup
#      rewrites the config and can silently change host and context
#    - a systemd service with the memlock limit the engine needs
#
#  Usage:
#    ./install-strata.sh                    IQ2_XS, localhost, service installed
#    ./install-strata.sh --check            preflight only, change nothing
#    ./install-strata.sh --model IQ3_S      a different size
#    ./install-strata.sh --context 65536    smaller context, less RAM
#    ./install-strata.sh --no-service       do not install the systemd unit
#    ./install-strata.sh --no-patch-cuda    do not touch CUDA's headers
#    ./install-strata.sh --dir /opt/Strata  where to install
#    ./install-strata.sh --help
#
#  Never run this with sudo. It calls sudo itself only where it must.
#  MIT licensed, like Strata. Upstream: https://github.com/Niko1221/Strata
# =============================================================================
set -euo pipefail

REPO_URL="https://github.com/Niko1221/Strata.git"
STRATA_DIR="${HOME}/Strata"
DATA_DIR=""
FAMILY="qwen"
MODEL="IQ2_XS"
CONTEXT=""
PORT="8080"
BACKEND=""
INSTALL_SERVICE=true
PATCH_CUDA=true
CHECK_ONLY=false
ASSUME_YES=false
GIT_REF=""

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'
CYA=$'\033[0;36m'; BLD=$'\033[1m'; RST=$'\033[0m'
info()  { printf '%s\n' "${CYA}  ${RST}$*"; }
ok()    { printf '%s\n' "${GRN}OK${RST} $*"; }
warn()  { printf '%s\n' "${YLW}!!${RST} $*" >&2; }
die()   { printf '%s\n' "${RED}xx${RST} $*" >&2; exit 1; }
step()  { printf '\n%s\n' "${BLD}== $*${RST}"; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)        STRATA_DIR="$2"; shift 2 ;;
        --data-dir)   DATA_DIR="$2";   shift 2 ;;
        --family)     FAMILY="$2";     shift 2 ;;
        --model)      MODEL="$2";      shift 2 ;;
        --context)    CONTEXT="$2";    shift 2 ;;
        --port)       PORT="$2";       shift 2 ;;
        --backend)    BACKEND="$2";    shift 2 ;;
        --ref)        GIT_REF="$2";    shift 2 ;;
        --no-service) INSTALL_SERVICE=false; shift ;;
        --no-patch-cuda) PATCH_CUDA=false; shift ;;
        --check)      CHECK_ONLY=true; shift ;;
        --yes|-y)     ASSUME_YES=true; shift ;;
        -h|--help)    usage ;;
        *)            die "unknown option: $1  (try --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] && die "do not run this as root or with sudo — run it as your normal user"
command -v sudo >/dev/null 2>&1 || die "sudo is required for the dependency step"

# -----------------------------------------------------------------------------
# CUDA / glibc guard
#
# glibc 2.41 added the C23 functions sinpi, sinpif, cospi and cospif and
# declared them noexcept. CUDA's crt/math_functions.h declares the same four
# without it, so nvcc refuses to compile anything at all:
#
#   error: exception specification is incompatible with that of previous
#   function "cospi"
#
# NVIDIA has not shipped a fix. Upgrading CUDA is not an escape on Pascal
# cards, because CUDA 13 dropped them. So the header gets patched in place,
# with a backup, unless --no-patch-cuda says otherwise.
# -----------------------------------------------------------------------------
cuda_glibc_guard() {
    [[ "$BACKEND" == "cuda" ]] || return 0

    local glibc nvcc root hdr
    glibc="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
    [[ -n "$glibc" ]] || return 0
    awk -v v="$glibc" 'BEGIN { split(v, a, "."); exit !(a[1] > 2 || (a[1] == 2 && a[2] >= 41)) }' \
        || { info "glibc ${glibc}: no CUDA header conflict"; return 0; }

    info "glibc ${glibc} conflicts with CUDA's math header"

    nvcc="$(command -v nvcc || true)"
    if [[ -n "$nvcc" ]]; then
        root="$(dirname "$(dirname "$(readlink -f "$nvcc")")")"
        hdr="${root}/targets/x86_64-linux/include/crt/math_functions.h"
    fi
    if [[ ! -f "${hdr:-}" ]]; then
        hdr="$(ls -1 /usr/local/cuda*/targets/x86_64-linux/include/crt/math_functions.h 2>/dev/null | tail -1 || true)"
    fi
    if [[ -z "${hdr:-}" || ! -f "$hdr" ]]; then
        warn "CUDA's math_functions.h was not found. If the build fails with"
        warn "'exception specification is incompatible', patch it by hand (see README)."
        return 0
    fi

    if grep -qE '^extern .*\bsinpi\([^)]*\) noexcept' "$hdr"; then
        ok "CUDA header already carries the glibc patch"
        return 0
    fi

    if [[ "$PATCH_CUDA" != true ]]; then
        warn "the CUDA header needs patching and --no-patch-cuda was given;"
        warn "the engine build will fail. See the README for the manual steps."
        return 0
    fi

    info "patching ${hdr}"
    sudo cp -n "$hdr" "${hdr}.bak" || true
    sudo sed -i -E 's/^(extern .*\b(sinpi|sinpif|cospi|cospif)\([^)]*\))[[:space:]]*;/\1 noexcept (true);/' "$hdr"
    if grep -qE '^extern .*\bsinpi\([^)]*\) noexcept' "$hdr"; then
        ok "CUDA header patched; undo with: sudo cp ${hdr}.bak ${hdr}"
        warn "a CUDA reinstall or upgrade undoes this. Rerun the installer if so."
    else
        die "the CUDA header patch did not apply. Patch it by hand - see the README."
    fi
}

# -----------------------------------------------------------------------------
# 1. Preflight
# -----------------------------------------------------------------------------
step "Checking this machine"

[[ -r /etc/os-release ]] || die "cannot read /etc/os-release — unsupported system"
# shellcheck disable=SC1091
. /etc/os-release
info "OS: ${PRETTY_NAME:-$NAME}"

RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
info "RAM: ${RAM_GB} GB"
(( RAM_GB >= 30 )) || die "need 32 GB of RAM or more; this machine has ${RAM_GB} GB"

mkdir -p "$(dirname "$STRATA_DIR")"
DISK_GB=$(df -BG --output=avail "$(dirname "$STRATA_DIR")" | tail -1 | tr -dc '0-9')
info "Free disk at $(dirname "$STRATA_DIR"): ${DISK_GB} GB"
(( DISK_GB >= 80 )) || die "need about 80 GB free; only ${DISK_GB} GB available"

# GPU / backend detection ------------------------------------------------------
GPU_DESC="none"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_DESC="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | head -1)"
    DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | cut -d. -f1)"
    CC="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)"
    [[ -n "$BACKEND" ]] || BACKEND="cuda"
    info "GPU: ${GPU_DESC}"

    # Pascal cards (Compute 6.x, e.g. Tesla P100 / P40) max out at driver 535 / 550 LTS.
    # Modern RTX cards (Turing/Ampere/Ada/Blackwell, Compute 7.x+) require 580+.
    if [[ "$CC" == 6.* ]]; then
        info "Detected Pascal GPU (compute ${CC}, e.g. Tesla P100/P40)."
        warn "Pascal uses legacy LTS drivers (535+); Strata will build from source via CUDA 12.x."
        if [[ "$DRV" =~ ^[0-9]+$ ]] && (( DRV < 535 )); then
            die "NVIDIA driver ${DRV} is too old for Pascal; Strata needs 535 or newer. Update it and rerun."
        fi
    else
        if [[ "$DRV" =~ ^[0-9]+$ ]] && (( DRV < 580 )); then
            die "NVIDIA driver ${DRV} is too old; Strata needs 580 or newer. Update it and rerun."
        fi
    fi
    # CUDA 13 dropped Pascal (compute 6.x). A P100 or P40 needs CUDA 12.x.
    if command -v nvcc >/dev/null 2>&1; then
        CUDAMAJ="$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+' | grep -oE '[0-9]+' || true)"
        if [[ "$CUDAMAJ" =~ ^[0-9]+$ ]] && (( CUDAMAJ >= 13 )) && [[ "$CC" == 6.* ]]; then
            die "CUDA ${CUDAMAJ} does not support this card (compute ${CC}, Pascal).
    CUDA 13 dropped Pascal. Install CUDA 12.x and rerun."
        fi
    fi
    [[ "$CC" == 6.* ]] && warn "Pascal (compute ${CC}) is an experimental upstream path; expect a source build."
    
elif lspci 2>/dev/null | grep -qiE 'vga|display|3d' && lspci | grep -qi 'amd/ati\|advanced micro devices'; then
    GPU_DESC="$(lspci | grep -iE 'vga|display|3d' | grep -i 'amd\|ati' | head -1 | cut -d: -f3-)"
    [[ -n "$BACKEND" ]] || BACKEND="hip"
    info "GPU:${GPU_DESC}"
elif lspci 2>/dev/null | grep -iE 'vga|display|3d' | grep -qi 'intel.*\(arc\|battlemage\|alchemist\|b[567]\)'; then
    GPU_DESC="$(lspci | grep -iE 'vga|display|3d' | grep -i intel | head -1 | cut -d: -f3-)"
    [[ -n "$BACKEND" ]] || BACKEND="sycl"
    info "GPU:${GPU_DESC}"
    warn "Intel Arc is an EXPERIMENTAL path upstream. It needs Docker and builds the"
    warn "engine from source (see docs/INTEL_ARC.md). Expect a longer install."
else
    die "no supported GPU found. Strata needs an NVIDIA RTX 20/30/40/50, a supported
    AMD Radeon, or an Intel Arc card with 12 GB of VRAM or more. Integrated GPUs
    are not supported."
fi
info "Backend: ${BACKEND}"

if [[ "$BACKEND" == "sycl" ]] && ! command -v docker >/dev/null 2>&1; then
    die "the Intel Arc path needs Docker: sudo apt install docker.io git,
    then sudo usermod -aG docker,render \$USER and log in again."
fi

# Model sizing against RAM -----------------------------------------------------
case "$MODEL" in
    Q2_0|IQ2_XS)      MIN_RAM=46 ;;
    IQ3_XXS|IQ3_S)    MIN_RAM=62 ;;
    IQ1_M)            MIN_RAM=30 ;;
    UD-IQ4_XS)        MIN_RAM=78 ;;
    *)                MIN_RAM=46 ;;
esac
if (( RAM_GB + 2 < MIN_RAM )); then
    warn "${MODEL} normally wants about ${MIN_RAM} GB of RAM and you have ${RAM_GB} GB."
    warn "It may run slowly by reading from the SSD, or not at all."
    if [[ "$ASSUME_YES" == false ]]; then
        read -r -p "Continue anyway? [y/N] " a; [[ "${a,,}" == y* ]] || exit 1
    fi
fi

cuda_glibc_guard

ok "preflight passed: ${FAMILY}/${MODEL}, backend ${BACKEND}"
if [[ "$CHECK_ONLY" == true ]]; then
    info "--check given; nothing was installed."
    exit 0
fi

# -----------------------------------------------------------------------------
# 2. Confirm the download
# -----------------------------------------------------------------------------
if [[ "$ASSUME_YES" == false ]]; then
    step "About to download roughly 70 GB"
    info "Model files go to ${DATA_DIR:-$(dirname "$STRATA_DIR")/Strata-data}"
    info "On a 100 Mbit line this takes 1.5-2 hours. It resumes if interrupted."
    read -r -p "Continue? [y/N] " a; [[ "${a,,}" == y* ]] || exit 1
fi

# -----------------------------------------------------------------------------
# 3. Dependencies
# -----------------------------------------------------------------------------
step "Installing dependencies"
if   command -v apt-get >/dev/null 2>&1; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git curl python3 python3-venv python3-pip ca-certificates
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git curl python3 python3-virtualenv ca-certificates
elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm --needed git curl python python-virtualenv ca-certificates
else
    die "unsupported package manager; install git, curl and python3-venv by hand and rerun"
fi
ok "dependencies installed"

# -----------------------------------------------------------------------------
# 4. Get Strata
# -----------------------------------------------------------------------------
step "Fetching Strata"
if [[ -d "$STRATA_DIR/.git" ]]; then
    info "already present, updating"
    if [[ -n "$GIT_REF" ]]; then
        git -C "$STRATA_DIR" fetch --quiet --depth=1 origin "$GIT_REF"
        git -C "$STRATA_DIR" checkout --quiet FETCH_HEAD
    else
        git -C "$STRATA_DIR" pull --quiet --ff-only || warn "could not fast-forward; keeping the current checkout"
    fi
else
    git clone --depth=1 ${GIT_REF:+--branch "$GIT_REF"} "$REPO_URL" "$STRATA_DIR"
fi
cd "$STRATA_DIR"
info "Strata at $(git rev-parse --short HEAD)"
ok "repository ready"

# -----------------------------------------------------------------------------
# 5. API key
# -----------------------------------------------------------------------------
step "Generating an API key"
KEY_FILE="${STRATA_DIR}/.strata-api-key"
if [[ -s "$KEY_FILE" ]]; then
    API_KEY="$(cat "$KEY_FILE")"
    info "reusing the existing key in ${KEY_FILE}"
else
    if command -v openssl >/dev/null 2>&1; then
        API_KEY="$(openssl rand -hex 32)"
    else
        API_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    umask 077
    printf '%s\n' "$API_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    ok "key written to ${KEY_FILE} (mode 600)"
fi

# -----------------------------------------------------------------------------
# 6. Run Strata's own setup
# -----------------------------------------------------------------------------
step "Running Strata setup (this is the long part)"
SETUP_ARGS=( --yes --family "$FAMILY" --model "$MODEL" --no-start
             --vision no --port "$PORT"
             --host 127.0.0.1 --api-key "$API_KEY" )
[[ -n "$CONTEXT"  ]] && SETUP_ARGS+=( --context  "$CONTEXT"  )
[[ -n "$DATA_DIR" ]] && SETUP_ARGS+=( --data-dir "$DATA_DIR" )
[[ -n "$BACKEND" && "$BACKEND" != "cuda" ]] && SETUP_ARGS+=( --backend "$BACKEND" )

chmod +x ./setup.sh
./setup.sh "${SETUP_ARGS[@]}"
ok "setup finished"

# -----------------------------------------------------------------------------
# 7. Re-assert the hardening
#
#    setup.sh rewrites strata-<model>.json. It has been observed to change the
#    bind address and to reduce --max-context from the machine's free RAM
#    without saying so. Verify rather than trust.
# -----------------------------------------------------------------------------
step "Verifying the configuration"
CFG="$(ls -1 "$STRATA_DIR"/strata-*.json 2>/dev/null | head -1 || true)"
[[ -n "$CFG" ]] || die "no strata-*.json was produced; setup did not complete"
info "config: $CFG"

python3 - "$CFG" "$PORT" <<'PY'
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
c = json.load(open(path))
changed = []
if c.get("host") != "127.0.0.1":
    c["host"] = "127.0.0.1"; changed.append("host -> 127.0.0.1")
if c.get("port") != port:
    c["port"] = port; changed.append(f"port -> {port}")
if not c.get("api_key"):
    print("WARNING: no api_key in the config", file=sys.stderr)
args = c.get("args", [])
if "--max-context" in args:
    print("context:", args[args.index("--max-context") + 1])
if changed:
    json.dump(c, open(path, "w"), indent=1)
    print("corrected:", ", ".join(changed))
else:
    print("host and port are as requested")
PY
ok "configuration verified"

RUN_SH="$(ls -1 "$STRATA_DIR"/run-*.sh 2>/dev/null | head -1 || true)"
[[ -n "$RUN_SH" ]] || die "setup wrote no run-*.sh start script"
chmod +x "$RUN_SH"
info "start script: $RUN_SH"

# -----------------------------------------------------------------------------
# 8. systemd service
# -----------------------------------------------------------------------------
if [[ "$INSTALL_SERVICE" == true ]]; then
    step "Installing the systemd service"
    UNIT=/etc/systemd/system/strata.service
    sudo tee "$UNIT" >/dev/null <<UNIT_EOF
[Unit]
Description=Strata (Qwen3.8-Flash-Next) local inference server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${USER}
WorkingDirectory=${STRATA_DIR}
ExecStart=${RUN_SH}
Restart=on-failure
RestartSec=30
# The engine locks a large part of RAM for the GPU. Without this it cannot start.
LimitMEMLOCK=infinity
# Hardening: the engine needs no privileges and writes only its own folders.
NoNewPrivileges=true
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
UNIT_EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now strata.service
    ok "service installed and started"

    info "waiting for the model to load (up to 5 minutes on a first start)"
    for i in $(seq 1 60); do
        if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
            ok "server is answering"
            break
        fi
        sleep 5
        (( i % 6 == 0 )) && info "still loading (${i}0 s)"
    done
fi

# -----------------------------------------------------------------------------
# 9. Done
# -----------------------------------------------------------------------------
step "Done"
HEALTH="$(curl -fsS "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo '(not answering yet)')"
printf '%s\n' "  health:   ${HEALTH}"
printf '%s\n' "  base URL: http://127.0.0.1:${PORT}/v1"
printf '%s\n' "  API key:  ${KEY_FILE}  (cat it; do not paste it anywhere public)"
cat <<'NOTES'

  Security defaults applied:
    - bound to 127.0.0.1 only, so nothing outside this machine can reach it
    - an API key is required even from this machine
    - image input is off, which removes the image-fetch code path entirely
    - the service runs as your user, not root

  To use it from another device, do NOT just change the bind address. Put it on
  a private network (WireGuard, Tailscale, NetBird) and bind there, or use an
  SSH tunnel:
      ssh -N -L 8080:127.0.0.1:8080 you@this-machine

  Service:   systemctl {status,restart,stop} strata
  Logs:      journalctl -u strata -f
  Reconfigure: cd <strata dir> && ./setup.sh --setup   # re-check the config after

NOTES
