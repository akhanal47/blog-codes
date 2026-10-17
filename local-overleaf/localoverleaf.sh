#!/usr/bin/env bash
# Handles:
#   - cloning overleaf/toolkit and running bin/init
#   - picking a MongoDB version that actually starts on this kernel
#     (MongoDB 8.0 refuses to start on Linux kernels 6.19 - 7.0.13, falls back to 8.2)
#   - required secrets (OVERLEAF_INVITE_TOKEN_SECRET) and compile timeout
#   - Apple Silicon / arm64 hosts (runs the Overleaf container as linux/amd64)
#   - two access modes: local only, or public via a Cloudflare tunnel
#   - optional full TeX Live (scheme-full), saved into a local image so it survives restarts


# Usage:
#   ./setup-overleaf.sh local [options]
#   ./setup-overleaf.sh cloudflared --hostname latex.example.com --tunnel-token <TOKEN> [options]

# Run with --help for all options.

set -euo pipefail

TOOLKIT_REPO="https://github.com/overleaf/toolkit.git"
TEXLIVE_SUFFIX="-with-texlive-full"
OVERRIDE_MARKER="# managed by setup-overleaf.sh"

# ---------- defaults ----------
MODE=""
FULL_TEXLIVE=false
TOOLKIT_DIR="./overleaf-toolkit"
PORT="80"
LISTEN_IP="127.0.0.1"
COMPILE_TIMEOUT="600"
MONGO_VERSION_OPT=""
PUBLIC_HOSTNAME=""
TUNNEL_TOKEN_OPT="${TUNNEL_TOKEN:-}"

# ---------- helpers ----------
log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Set up Overleaf Community Edition with the official overleaf/toolkit.

Usage:
  ./setup-overleaf.sh local [options]
  ./setup-overleaf.sh cloudflared --hostname HOST --tunnel-token TOKEN [options]

Modes:
  local           Overleaf reachable only at http://<listen-ip>:<port> on this machine/LAN. Use a SSH tunnel if your hosting and use machine are different but are on same network
  cloudflared     Overleaf exposed publicly through a Cloudflare tunnel at https://HOST

Options:
  --full-texlive            Install TeX Live scheme-full (~4-5 GB extra, 30-60+ min)
                            and save it into a local image so it survives restarts
  --dir PATH                Toolkit directory (default: ./overleaf-toolkit; cloned if missing)
  --port N                  Host port for Overleaf (default: 80)
  --listen-ip IP            Host IP to bind (default: 127.0.0.1; 0.0.0.0 = whole LAN)
  --compile-timeout SECS    LaTeX compile timeout in seconds (default: 600)
  --mongo-version X.Y       Force a MongoDB version (default: auto, tries 8.0 then 8.2)
  --hostname HOST           Public hostname, e.g. latex.example.com (cloudflared mode)
  --tunnel-token TOKEN      Cloudflare tunnel token (cloudflared mode; or env TUNNEL_TOKEN)
  -h, --help                Show this help

Cloudflare side (cloudflared mode), done once in the Zero Trust dashboard:
  Networks -> Tunnels -> Create tunnel (Cloudflared) -> copy the token,
  then add a Public Hostname: HOST  ->  Service HTTP, URL  sharelatex:80

Examples:
  ./setup-overleaf.sh local --full-texlive
  ./setup-overleaf.sh local --port 8080 --listen-ip 0.0.0.0
  ./setup-overleaf.sh cloudflared --hostname latex.example.com --tunnel-token eyJ... --full-texlive

Re-running is safe: existing config, secrets and data are kept.
For long installs over SSH, run inside tmux or screen.
EOF
}

# Set KEY=VALUE in an env-style file.
# Replaces an existing active line; otherwise uncomments a commented one; otherwise appends.
set_kv() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    NR == FNR { if ($0 ~ "^[[:space:]]*" k "=") has = 1; next }
    {
      if (!done && ((has && $0 ~ "^[[:space:]]*" k "=") ||
                    (!has && $0 ~ "^[[:space:]]*#[[:space:]]*" k "="))) {
        print k "=" v; done = 1; next
      }
      print
    }
    END { if (!done) print k "=" v }
  ' "$file" "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Comment out KEY in an env-style file (Overleaf treats any set value as "on").
unset_kv() {
  local file="$1" key="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*" k "=" { print "# " $0; next }
    { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Read the last active value of KEY from an env-style file.
get_kv() {
  local file="$1" key="$2"
  grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

# Start a throwaway mongo container and check whether it actually starts.
probe_mongo() {
  local ver="$1" name="overleaf-mongo-probe-$$" out i
  docker rm -f "$name" >/dev/null 2>&1 || true
  if ! docker run -d --name "$name" "mongo:${ver}" >/dev/null 2>&1; then
    return 1
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 10
    out="$(docker logs "$name" 2>&1 || true)"
    if grep -q "cannot start" <<<"$out"; then
      docker rm -f "$name" >/dev/null 2>&1 || true
      return 1
    fi
    if grep -q "Waiting for connections" <<<"$out"; then
      docker rm -f "$name" >/dev/null 2>&1 || true
      return 0
    fi
  done
  docker rm -f "$name" >/dev/null 2>&1 || true
  return 1
}

# Wait until the sharelatex container is running, not restarting, and finished booting.
wait_for_sharelatex() {
  local i stable=0 state
  info "Waiting for the Overleaf container to finish booting..."
  for i in $(seq 1 90); do
    state="$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' sharelatex 2>/dev/null || echo "missing")"
    if [[ "$state" == "true false" ]]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    if docker logs sharelatex 2>&1 | grep -q "Refusing to startup"; then
      docker logs --tail 40 sharelatex 2>&1 || true
      die "Overleaf refused to start (see log above)."
    fi
    if (( stable >= 3 )) && docker logs sharelatex 2>&1 | grep -q "Runit started"; then
      info "Overleaf is up."
      return 0
    fi
    sleep 40
  done
  docker logs --tail 40 sharelatex 2>&1 || true
  die "Overleaf did not become ready in time (see log above)."
}

# ---------- argument parsing ----------
case "${1:-}" in
  local|cloudflared) MODE="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
  "") usage; exit 1 ;;
  *) die "Unknown mode '$1'. Use 'local' or 'cloudflared' (see --help)." ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-texlive)    FULL_TEXLIVE=true; shift ;;
    --dir)             TOOLKIT_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --port)            PORT="${2:?--port needs a value}"; shift 2 ;;
    --listen-ip)       LISTEN_IP="${2:?--listen-ip needs a value}"; shift 2 ;;
    --compile-timeout) COMPILE_TIMEOUT="${2:?--compile-timeout needs a value}"; shift 2 ;;
    --mongo-version)   MONGO_VERSION_OPT="${2:?--mongo-version needs a value}"; shift 2 ;;
    --hostname)        PUBLIC_HOSTNAME="${2:?--hostname needs a value}"; shift 2 ;;
    --tunnel-token)    TUNNEL_TOKEN_OPT="${2:?--tunnel-token needs a value}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) die "Unknown option '$1' (see --help)." ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number."
[[ "$COMPILE_TIMEOUT" =~ ^[0-9]+$ ]] || die "--compile-timeout must be a number of seconds."

if [[ "$MODE" == "cloudflared" ]]; then
  [[ -n "$PUBLIC_HOSTNAME" ]] || die "cloudflared mode needs --hostname (e.g. latex.example.com)."
  PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME#https://}"
  PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME#http://}"
  PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME%/}"
fi

# ---------- prerequisites ----------
log "Checking prerequisites"
for cmd in docker git openssl awk; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
done
docker info >/dev/null 2>&1 || die "Cannot talk to Docker. Is it running, and is your user in the 'docker' group?"

OS="$(uname -s)"
ARCH="$(uname -m)"
info "Host: ${OS} ${ARCH}"

if [[ "$OS" == "Darwin" ]]; then
  # The toolkit's scripts rely on GNU sed behaviour; BSD sed breaks MONGO_VERSION parsing.
  if ! sed --version 2>/dev/null | grep -q "GNU"; then
    die "macOS detected: the toolkit needs GNU sed.
       brew install gnu-sed
       export PATH=\"\$(brew --prefix)/opt/gnu-sed/libexec/gnubin:\$PATH\"
     then re-run this script."
  fi
fi

NEEDS_AMD64_EMULATION=false
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  NEEDS_AMD64_EMULATION=true
  warn "arm64 host: the Overleaf image is amd64-only and will run under emulation (slower compiles)."
  if [[ "$OS" == "Darwin" ]]; then
    warn "Enable Docker Desktop -> Settings -> General -> 'Use Rosetta for x86_64/amd64 emulation'."
  else
    warn "Make sure amd64 emulation (qemu-user-static / binfmt) is installed on this host."
  fi
fi

# ---------- toolkit ----------
log "Preparing overleaf/toolkit"
if [[ ! -d "$TOOLKIT_DIR" ]]; then
  git clone "$TOOLKIT_REPO" "$TOOLKIT_DIR"
else
  info "Using existing directory: $TOOLKIT_DIR"
fi
TOOLKIT_DIR_ABS="$(cd "$TOOLKIT_DIR" && pwd)"
cd "$TOOLKIT_DIR_ABS"
[[ -x bin/init && -x bin/up ]] || die "$TOOLKIT_DIR_ABS does not look like overleaf/toolkit."

if [[ ! -f config/overleaf.rc ]]; then
  bin/init
else
  info "Config already exists, keeping it."
fi

RC=config/overleaf.rc
VARS=config/variables.env
OVERRIDE=config/docker-compose.override.yml
CF_ENV=config/cloudflared.env

# ---------- MongoDB version ----------
log "Choosing MongoDB version"
MONGO_DATA_PATH="$(get_kv "$RC" MONGO_DATA_PATH)"
MONGO_DATA_PATH="${MONGO_DATA_PATH:-data/mongo}"
CURRENT_MONGO="$(get_kv "$RC" MONGO_VERSION)"

if [[ -n "$MONGO_VERSION_OPT" ]]; then
  MONGO_VERSION="$MONGO_VERSION_OPT"
  info "Using forced version: $MONGO_VERSION"
elif [[ -d "$MONGO_DATA_PATH" && -n "$(ls -A "$MONGO_DATA_PATH" 2>/dev/null)" ]]; then
  MONGO_VERSION="$CURRENT_MONGO"
  info "Existing Mongo data found, keeping version ${MONGO_VERSION} (use --mongo-version to change)."
else
  MONGO_VERSION=""
  for v in 8.0 8.2; do
    info "Testing mongo:${v} on this kernel..."
    if probe_mongo "$v"; then
      MONGO_VERSION="$v"
      break
    fi
    info "mongo:${v} does not start here."
  done
  [[ -n "$MONGO_VERSION" ]] || die "No supported MongoDB version starts on this host. Try --mongo-version."
  info "Selected mongo:${MONGO_VERSION}"
fi

# ---------- overleaf.rc ----------
log "Writing config/overleaf.rc"
set_kv "$RC" MONGO_VERSION "$MONGO_VERSION"
set_kv "$RC" SIBLING_CONTAINERS_ENABLED "false"
set_kv "$RC" OVERLEAF_LISTEN_IP "$LISTEN_IP"
set_kv "$RC" OVERLEAF_PORT "$PORT"

# ---------- variables.env ----------
log "Writing config/variables.env"
if [[ -z "$(get_kv "$VARS" OVERLEAF_INVITE_TOKEN_SECRET)" ]]; then
  set_kv "$VARS" OVERLEAF_INVITE_TOKEN_SECRET "$(openssl rand -base64 32)"
  info "Generated OVERLEAF_INVITE_TOKEN_SECRET."
else
  info "Keeping existing OVERLEAF_INVITE_TOKEN_SECRET."
fi
set_kv "$VARS" COMPILE_TIMEOUT "$COMPILE_TIMEOUT"

if [[ "$MODE" == "cloudflared" ]]; then
  set_kv "$VARS" OVERLEAF_SITE_URL "https://${PUBLIC_HOSTNAME}"
  set_kv "$VARS" OVERLEAF_BEHIND_PROXY "true"
  set_kv "$VARS" OVERLEAF_SECURE_COOKIE "true"
else
  if [[ "$PORT" == "80" ]]; then
    set_kv "$VARS" OVERLEAF_SITE_URL "http://localhost"
  else
    set_kv "$VARS" OVERLEAF_SITE_URL "http://localhost:${PORT}"
  fi

  # Overleaf treats these as enabled whenever they are set, even to "false".
  unset_kv "$VARS" OVERLEAF_BEHIND_PROXY
  unset_kv "$VARS" OVERLEAF_SECURE_COOKIE
fi

# ---------- cloudflared token ----------
if [[ "$MODE" == "cloudflared" ]]; then
  log "Writing Cloudflare tunnel token"
  if [[ -n "$TUNNEL_TOKEN_OPT" ]]; then
    (umask 077; printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN_OPT" > "$CF_ENV")
    info "Saved token to $CF_ENV"
  elif [[ -s "$CF_ENV" ]]; then
    info "Reusing existing token in $CF_ENV"
  else
    die "cloudflared mode needs --tunnel-token (or env TUNNEL_TOKEN)."
  fi
fi

# ---------- docker-compose.override.yml ----------
log "Writing config/docker-compose.override.yml"
if [[ -f "$OVERRIDE" ]] && ! grep -qF "$OVERRIDE_MARKER" "$OVERRIDE"; then
  backup="${OVERRIDE}.bak.$(date +%s)"
  cp "$OVERRIDE" "$backup"
  warn "Existing override was not created by this script; backed up to $backup"
fi

if [[ "$NEEDS_AMD64_EMULATION" == true || "$MODE" == "cloudflared" ]]; then
  {
    echo "$OVERRIDE_MARKER (regenerated on every run)"
    echo "services:"
    if [[ "$NEEDS_AMD64_EMULATION" == true ]]; then
      echo "  sharelatex:"
      echo "    platform: linux/amd64"
    fi
    if [[ "$MODE" == "cloudflared" ]]; then
      echo "  cloudflared:"
      echo "    image: cloudflare/cloudflared:latest"
      echo "    container_name: overleaf_cloudflared"
      echo "    command: tunnel --no-autoupdate run"
      echo "    env_file:"
      echo "      - ${TOOLKIT_DIR_ABS}/${CF_ENV}"
      echo "    depends_on:"
      echo "      - sharelatex"
      echo "    restart: unless-stopped"
    fi
  } > "$OVERRIDE"
  info "Override written."
else
  rm -f "$OVERRIDE"
  info "No override needed."
fi

if [[ "$MODE" == "local" ]]; then
  docker rm -f overleaf_cloudflared >/dev/null 2>&1 || true
fi

# ---------- image version ----------
IMAGE_NAME="$(get_kv "$RC" OVERLEAF_IMAGE_NAME)"
IMAGE_NAME="${IMAGE_NAME:-sharelatex/sharelatex}"
CURRENT_VERSION="$(tr -d '[:space:]' < config/version)"
BASE_VERSION="${CURRENT_VERSION%"$TEXLIVE_SUFFIX"}"

if [[ "$CURRENT_VERSION" != "$BASE_VERSION" ]] && ! docker image inspect "${IMAGE_NAME}:${CURRENT_VERSION}" >/dev/null 2>&1; then
  warn "Image ${IMAGE_NAME}:${CURRENT_VERSION} not found locally; falling back to ${BASE_VERSION}."
  echo "$BASE_VERSION" > config/version
  CURRENT_VERSION="$BASE_VERSION"
fi

# ---------- start ----------
log "Starting Overleaf (first run pulls images, this can take a while)"
bin/up -d
wait_for_sharelatex

# ---------- full TeX Live ----------
if [[ "$FULL_TEXLIVE" == true ]]; then
  log "Installing full TeX Live"
  TEX_TAG="${BASE_VERSION}${TEXLIVE_SUFFIX}"

  if [[ "$CURRENT_VERSION" == "$TEX_TAG" ]]; then
    info "Already running ${IMAGE_NAME}:${TEX_TAG}, skipping."
  else
    if [[ "$OS" == "Linux" ]]; then
      DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
      AVAIL_KB="$(df -Pk "$DOCKER_ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
      if [[ -n "$AVAIL_KB" ]] && (( AVAIL_KB < 10 * 1024 * 1024 )); then
        die "Less than 10 GB free under ${DOCKER_ROOT}; full TeX Live needs about that much."
      fi
    fi

    info "This may take 30-60+ minutes or longer depening upon network speeds. Do not interrupt it."
    docker exec sharelatex tlmgr update --self \
      || die "tlmgr self-update failed. If the error mentions an older TeX Live year, upgrade the Overleaf image first."
    docker exec sharelatex tlmgr install scheme-full \
      || die "TeX Live install failed. Re-run the script with --full-texlive to resume."
    docker exec sharelatex tlmgr path add

    docker exec sharelatex kpsewhich booktabs.sty >/dev/null 2>&1 \
      || die "Install finished but packages are not found (kpsewhich booktabs.sty failed)."

    log "Saving container as ${IMAGE_NAME}:${TEX_TAG}"
    docker commit sharelatex "${IMAGE_NAME}:${TEX_TAG}" >/dev/null
    echo "$TEX_TAG" > config/version

    log "Restarting on the TeX Live image"
    bin/up -d
    wait_for_sharelatex
    docker exec sharelatex kpsewhich booktabs.sty >/dev/null 2>&1 \
      || die "Restarted container is missing TeX Live packages; check config/version."
    info "Full TeX Live is baked into ${IMAGE_NAME}:${TEX_TAG}."
  fi
fi

# summary of things completed
if [[ "$MODE" == "cloudflared" ]]; then
  URL="https://${PUBLIC_HOSTNAME}"
elif [[ "$PORT" == "80" ]]; then
  URL="http://localhost"
else
  URL="http://localhost:${PORT}"
fi

log "Done"
info "Overleaf:        ${URL}"
info "Create admin:    ${URL}/launchpad   (first run only)"
info "Toolkit dir:     ${TOOLKIT_DIR_ABS}"
info "MongoDB:         ${MONGO_VERSION}"
info "Overleaf image:  ${IMAGE_NAME}:$(tr -d '[:space:]' < config/version)"
info "Compile timeout: ${COMPILE_TIMEOUT}s"
if [[ "$MODE" == "cloudflared" ]]; then
  info "Tunnel logs:     docker logs --tail 20 overleaf_cloudflared"
  info "Note: Cloudflare ends any single request after ~100s, so compiles longer than that return a 524 over the public URL."
fi
info "Note: Community Edition compiles are not sandboxed; ONLY GIVE accounts to trusted users."