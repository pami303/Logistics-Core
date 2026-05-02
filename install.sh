#!/bin/bash
# ==================================================
# LOGISTICS ENGINE — INSTALLER v3
# Ubuntu 24.04 (noble) hardened edition:
#   • Deadsnakes-first (standard apt skipped on noble)
#   • /etc/apt/keyrings/ + signed-by GPG practice
#   • Multi-keyserver fallback with port-80 backup
#   • DEBIAN_FRONTEND=noninteractive throughout
#   • uv for fast venv + dependency install
#   • Parallel apt + pip/uv optimisations
# ==================================================

# NOTE: We intentionally do NOT use `set -e` here.
# Every command is checked explicitly so failures are
# caught with a clear message instead of a silent exit.

export DEBIAN_FRONTEND=noninteractive

# --- Terminal Colors ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ZIP_URL="https://github.com/pami303/Logistics-Core/raw/refs/heads/main/core.zip"
ZIP_PATH="/tmp/core.zip"

DEADSNAKES_FINGERPRINT="F23C5A6CF475977595C89F51BA6932366A755776"
KEYRINGS_DIR="/etc/apt/keyrings"
DEADSNAKES_GPG="$KEYRINGS_DIR/deadsnakes.gpg"

# ==================================================
# HELPERS
# ==================================================

log_info()    { echo -e "${CYAN}  →${NC} $1"; }
log_ok()      { echo -e "${GREEN}  ✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}  ⚠${NC} $1"; }
log_section() { echo -e "\n${BOLD}${YELLOW}[$1]${NC} $2"; }

fatal() {
    echo -e "\n${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  FATAL ERROR                                     ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "${RED}$1${NC}\n"
    [[ -d /opt/logistics_bot ]] && { log_warn "Cleaning up /opt/logistics_bot ..."; sudo rm -rf /opt/logistics_bot; }
    rm -f "$ZIP_PATH" 2>/dev/null
    exit 1
}

echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}LOGISTICS ENGINE — INSTALLER${NC}${CYAN}                   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

# ==================================================
# STEP 1 — BASE SYSTEM PACKAGES
# ==================================================
log_section "1/6" "Installing base system packages"

# Single update pass — parallelism via apt's own HTTP pipeline
sudo apt-get update -y -q > /dev/null 2>&1 || log_warn "apt update had warnings — continuing anyway"

# gnupg2 is what Ubuntu 24.04 ships; curl is needed for key fetch below.
# build-essential / libssl-dev / libffi-dev are only needed for source builds
# so we defer them to the source-build fallback (Method C) to save time on
# the happy path.
BASE_PKGS="unzip wget curl gnupg2 ca-certificates software-properties-common"

log_info "Installing base packages..."
sudo apt-get install -y -q $BASE_PKGS > /dev/null 2>&1
if [[ $? -ne 0 ]]; then
    log_warn "Silent install had issues, retrying with output visible..."
    sudo apt-get install -y $BASE_PKGS || fatal "Could not install base packages. Check your apt sources."
fi
log_ok "Base packages ready"

# ==================================================
# STEP 2 — PYTHON 3.11
# Ubuntu 24.04 (noble): python3.11 is NOT in the universe repo — deadsnakes
# is the only apt-based path. Method A (plain apt) is left as a fast probe
# but will almost always be a no-op on noble; it costs one apt-cache lookup.
# ==================================================
log_section "2/6" "Ensuring Python 3.11 is available"

PY311=$(command -v python3.11 2>/dev/null || true)

if [[ -n "$PY311" ]]; then
    log_ok "Python 3.11 already installed: $PY311"
else
    # ---- Method A: plain apt probe (succeeds on 22.04, nearly always a
    #      no-op on 24.04 but costs almost nothing to try) ----
    log_info "Method A: probing standard apt repos..."
    sudo apt-get install -y -q python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1
    PY311=$(command -v python3.11 2>/dev/null || true)

    if [[ -z "$PY311" ]]; then
        # ---- Method B: deadsnakes PPA with /etc/apt/keyrings/ + signed-by
        #      (correct Ubuntu 24.04 GPG practice; avoids the deprecated
        #      trusted.gpg.d and the old add-apt-repository key injection) ----
        log_info "Method B: adding deadsnakes PPA (modern GPG practice)..."

        CODENAME=$(lsb_release -sc 2>/dev/null \
            || grep VERSION_CODENAME /etc/os-release | cut -d= -f2 \
            || echo "noble")
        sudo mkdir -p "$KEYRINGS_DIR"

        # ---- IMPORTANT: always wipe any leftover key file from a previous
        #      failed run before writing a new one.  A prior partial write
        #      can produce a non-empty but corrupt .gpg that passes the -s
        #      size test yet makes apt-get update fail silently.
        sudo rm -f "$DEADSNAKES_GPG"

        # Also remove any stale deadsnakes sources list left over from a
        # previous run that used a different (or no) signed-by path — having
        # two entries for the same PPA causes apt-get update to error.
        sudo rm -f /etc/apt/sources.list.d/deadsnakes*.list \
                   /etc/apt/trusted.gpg.d/deadsnakes*.gpg 2>/dev/null || true

        # Try fetching the key from multiple sources in order of reliability.
        # 1) HTTPS REST endpoint  (no HKP firewall issues, port 443)
        # 2) HKP port 80 fallback (port 11371 is often blocked on cloud VMs)
        # 3) keys.openpgp.org      (independent network, good uptime)
        KEY_FETCHED=false

        for KEY_URL in \
            "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${DEADSNAKES_FINGERPRINT}" \
            "http://keyserver.ubuntu.com:80/pks/lookup?op=get&search=0x${DEADSNAKES_FINGERPRINT}" \
            "https://keys.openpgp.org/vks/v1/by-fingerprint/${DEADSNAKES_FINGERPRINT}"
        do
            log_info "  Trying key source: $(echo "$KEY_URL" | cut -d/ -f1-3)..."

            # Write to a temp file first so a failed fetch never leaves a
            # partial/corrupt file at $DEADSNAKES_GPG.
            # Two-step fetch: download first, then dearmor separately.
            # Piping curl|gpg means bash only sees gpg's exit code — a
            # network failure in curl is silently ignored if gpg exits 0
            # on an empty/partial input.
            TMP_ASC=$(sudo mktemp)
            TMP_GPG=$(sudo mktemp)
            if curl -fsSL --max-time 15 "$KEY_URL" -o "$TMP_ASC" 2>/dev/null \
               && [[ -s "$TMP_ASC" ]] \
               && sudo gpg --dearmor -o "$TMP_GPG" < "$TMP_ASC" 2>/dev/null \
               && [[ -s "$TMP_GPG" ]]; then
                sudo mv "$TMP_GPG" "$DEADSNAKES_GPG"
                sudo chmod 644 "$DEADSNAKES_GPG"
                KEY_FETCHED=true
                rm -f "$TMP_ASC"
                log_ok "  Key fetched successfully"
                break
            fi
            rm -f "$TMP_ASC"
            sudo rm -f "$TMP_GPG" "$DEADSNAKES_GPG"
        done

        if $KEY_FETCHED; then
            # Correct Ubuntu 24.04 practice: signed-by= scopes the key to
            # this repo only; arch= avoids "skipping non-matching" warnings.
            echo "deb [arch=$(dpkg --print-architecture) signed-by=${DEADSNAKES_GPG}] \
https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu ${CODENAME} main" \
                | sudo tee /etc/apt/sources.list.d/deadsnakes.list > /dev/null

            if ! sudo apt-get update -y -q > /dev/null 2>&1; then
                log_warn "apt-get update failed after adding deadsnakes — showing errors:"
                sudo apt-get update 2>&1 | tail -10 || true
            fi
            if sudo apt-get install -y -q python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1; then
                PY311=$(command -v python3.11 2>/dev/null || true)
            else
                # apt-get install failed — show why before falling through
                log_warn "deadsnakes apt install failed — stderr follows:"
                sudo apt-get install -y python3.11 python3.11-venv python3.11-dev 2>&1 | head -20 || true
            fi
        fi

        if [[ -z "$PY311" ]]; then
            # Sub-fallback: add-apt-repository
            # Only reached if every key URL above truly failed (network issue).
            log_warn "Key fetch failed — trying add-apt-repository fallback..."

            # Clean slate again before add-apt-repository writes its own files
            sudo rm -f /etc/apt/sources.list.d/deadsnakes*.list \
                       /etc/apt/trusted.gpg.d/deadsnakes*.gpg \
                       "$DEADSNAKES_GPG" 2>/dev/null || true

            sudo DEBIAN_FRONTEND=noninteractive \
                add-apt-repository -y ppa:deadsnakes/ppa > /dev/null 2>&1 || true

            # add-apt-repository on Ubuntu 24.04 still drops the key into the
            # deprecated trusted.gpg.d — migrate it to /etc/apt/keyrings/ and
            # patch the sources line to use signed-by= so apt doesn't warn.
            LEGACY_GPG=$(find /etc/apt/trusted.gpg.d/ -maxdepth 1 -name "deadsnakes*.gpg" -print 2>/dev/null | head -1 || true)
            if [[ -n "$LEGACY_GPG" ]]; then
                sudo cp "$LEGACY_GPG" "$DEADSNAKES_GPG"
                sudo chmod 644 "$DEADSNAKES_GPG"
                sudo rm -f "$LEGACY_GPG"
                # Patch whatever sources file add-apt-repository wrote
                SOURCES_FILE=$(find /etc/apt/sources.list.d/ -maxdepth 1 -name "deadsnakes*.list" -print 2>/dev/null | head -1 || true)
                if [[ -n "$SOURCES_FILE" ]]; then
                    ARCH=$(dpkg --print-architecture)
                    sudo sed -i \
                        "s|^deb |deb [arch=${ARCH} signed-by=${DEADSNAKES_GPG}] |" \
                        "$SOURCES_FILE" 2>/dev/null || true
                fi
            fi

            sudo apt-get update -y -q > /dev/null 2>&1
            sudo apt-get install -y -q python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1
            PY311=$(command -v python3.11 2>/dev/null || true)
        fi
    fi

    if [[ -z "$PY311" ]]; then
        # ---- Method C: compile from source (~8 min, last resort) ----
        log_warn "PPA methods failed. Compiling Python 3.11 from source..."
        log_warn "This will take approximately 8-10 minutes. Please wait..."

        # Install build deps (deferred from Step 1 to keep happy-path fast)
        sudo apt-get install -y -q \
            build-essential libssl-dev libffi-dev python3-pip \
            zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
            libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
            liblzma-dev > /dev/null 2>&1 || true

        PY_SRC_DIR=$(mktemp -d)
        cd "$PY_SRC_DIR" || fatal "Could not create temp directory for Python source build"

        log_info "Downloading Python 3.11.9 source..."
        wget -q "https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz" \
            || fatal "Could not download Python 3.11.9 source. Check network connectivity."

        tar -xzf Python-3.11.9.tgz
        cd Python-3.11.9 || fatal "Could not enter Python source directory"

        log_info "Configuring..."
        # --enable-optimizations adds ~30% speed but doubles compile time;
        # use --with-lto as a lighter alternative.
        ./configure --with-lto --prefix=/usr/local > /dev/null 2>&1 \
            || fatal "Python ./configure failed"

        log_info "Compiling (please wait ~8 minutes)..."
        make -j"$(nproc)" > /dev/null 2>&1 \
            || fatal "Python make failed"

        log_info "Installing..."
        sudo make altinstall > /dev/null 2>&1 \
            || fatal "Python make altinstall failed"

        cd /
        sudo rm -rf "$PY_SRC_DIR"

        PY311=$(command -v python3.11 2>/dev/null || true)
        [[ -n "$PY311" ]] && "$PY311" -m ensurepip --upgrade > /dev/null 2>&1 || true
    fi
fi

[[ -z "$PY311" ]] && fatal "All three Python 3.11 installation methods failed.\nPlease install Python 3.11 manually and re-run this installer."

# Ensure venv module is available (deadsnakes splits it into a separate pkg)
if ! python3.11 -m venv --help > /dev/null 2>&1; then
    log_info "Installing python3.11-venv module..."
    sudo apt-get install -y -q python3.11-venv > /dev/null 2>&1 || \
    sudo apt-get install -y -q python3-venv     > /dev/null 2>&1 || true
fi

PY_VERSION=$(python3.11 --version 2>&1)
log_ok "Python 3.11 ready: $PY_VERSION"

# ==================================================
# STEP 3 — DOWNLOAD & UNPACK
# ==================================================
log_section "3/6" "Downloading application files"

log_info "Fetching core.zip from GitHub..."
wget -q --tries=3 --timeout=60 -O "$ZIP_PATH" "$ZIP_URL"
[[ $? -ne 0 ]] && fatal "Download failed.\nURL: $ZIP_URL\nCheck network and GitHub repo availability."
log_ok "Download complete"

sudo rm -rf /opt/logistics_bot
sudo mkdir -p /opt/logistics_bot

TMP_UNZIP=$(mktemp -d)
log_info "Extracting..."
sudo unzip -q "$ZIP_PATH" -d "$TMP_UNZIP" \
    || fatal "Failed to extract core.zip. The file may be corrupted."

# Auto-flatten single wrapper folder if present.
# Use a bash glob array instead of parsing `ls` output — ls piped into
# wc/head is unsafe when filenames contain spaces or glob characters.
mapfile -t TOP_ENTRIES < <(find "$TMP_UNZIP" -mindepth 1 -maxdepth 1)
TOP_COUNT=${#TOP_ENTRIES[@]}
TOP_ENTRY="${TOP_ENTRIES[0]}"

if [[ "$TOP_COUNT" -eq 1 && -d "$TOP_ENTRY" ]]; then
    FOLDER_NAME=$(basename "$TOP_ENTRY")
    log_info "Detected wrapper folder '$FOLDER_NAME' — flattening..."
    sudo cp -r "$TOP_ENTRY/." /opt/logistics_bot/
else
    sudo cp -r "$TMP_UNZIP/." /opt/logistics_bot/
fi

sudo rm -rf "$TMP_UNZIP"
cd /opt/logistics_bot || fatal "Could not enter /opt/logistics_bot"
log_ok "Files extracted to /opt/logistics_bot"

# ==================================================
# STEP 4 — PYARMOR RUNTIME INTEGRITY CHECK
# ==================================================
log_section "4/6" "Verifying PyArmor runtime integrity"

PYARMOR_DIR="pyarmor_runtime_000000"
PYARMOR_INIT="$PYARMOR_DIR/__init__.py"
PYARMOR_SO="$PYARMOR_DIR/pyarmor_runtime.so"

[[ ! -d "$PYARMOR_DIR" ]] && \
    fatal "PyArmor runtime directory '$PYARMOR_DIR' not found.\nRe-zip the contents of your PyArmor dist/ output folder."

[[ ! -f "$PYARMOR_INIT" ]] && \
    fatal "'$PYARMOR_INIT' is missing.\nThis file is required so Python treats the directory as a package."

[[ ! -f "$PYARMOR_SO" ]] && \
    fatal "'$PYARMOR_SO' is missing.\nRe-run: pyarmor gen -O dist --platform linux.x86_64 .\nThen re-zip the dist/ contents."

log_ok "Runtime directory and files present"

if command -v file > /dev/null 2>&1; then
    FILE_OUT=$(file "$PYARMOR_SO")
    if echo "$FILE_OUT" | grep -qi "PE32\|PE64\|MS Windows\|DLL"; then
        fatal "pyarmor_runtime.so is a Windows binary, not a Linux binary.\nRe-run: pyarmor gen -O dist --platform linux.x86_64 ."
    elif echo "$FILE_OUT" | grep -q "ELF 64-bit"; then
        log_ok "Runtime is a valid Linux x86_64 ELF binary"
    else
        log_warn "Could not confirm ELF type — proceeding anyway"
    fi
fi

# ==================================================
# STEP 5 — PYTHON ENVIRONMENT & DEPENDENCIES
# Use uv if available (10-100× faster than pip for cold installs);
# fall back to plain pip otherwise.
# ==================================================
log_section "5/6" "Creating Python 3.11 virtual environment"

# Try to install uv (single static binary, very fast).
# Install to /usr/local/bin so it lands on PATH regardless of whether
# the script runs as root (sudo bash, HOME=/root) or a regular user.
# The default ~/.local/bin install is not reliable under `sudo bash`
# because that dir may not be on PATH yet in the root environment.
UV_BIN=""
if ! command -v uv > /dev/null 2>&1; then
    log_info "Installing uv (fast Python package manager)..."
    curl -fsSL --max-time 20 https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin sh > /dev/null 2>&1 || true
fi
UV_BIN=$(command -v uv 2>/dev/null || true)

log_info "Initialising venv..."
if [[ -n "$UV_BIN" ]]; then
    "$UV_BIN" venv --python python3.11 venv > /dev/null 2>&1 \
        || python3.11 -m venv venv \
        || fatal "venv creation failed.\nTry: sudo apt-get install -y python3.11-venv"
else
    python3.11 -m venv venv \
        || fatal "python3.11 -m venv failed.\nTry: sudo apt-get install -y python3.11-venv"
fi
log_ok "Virtual environment created"

DEPS="cryptography python-telegram-bot httpx python-dotenv aiofiles rich PyJWT[crypto] psutil"

if [[ -n "$UV_BIN" ]]; then
    log_info "Installing dependencies via uv (fast path)..."
    # uv resolves and installs in parallel; --no-cache is omitted so repeated
    # runs benefit from the local uv cache (~/.cache/uv).
    # uv pip looks for a venv named .venv by default; ours is named
    # "venv". Point it explicitly via VIRTUAL_ENV so uv installs into
    # the correct environment without needing --python.
    VIRTUAL_ENV="$(pwd)/venv" \
        "$UV_BIN" pip install $DEPS > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        log_warn "uv silent install failed — retrying with output..."
        VIRTUAL_ENV="$(pwd)/venv" \
            "$UV_BIN" pip install $DEPS \
            || fatal "Dependency installation failed. See output above."
    fi
else
    log_info "Upgrading pip / setuptools / wheel..."
    ./venv/bin/python -m pip install -q --upgrade pip setuptools wheel \
        || fatal "pip upgrade failed"

    log_info "Installing dependencies via pip..."
    # --only-binary :all: avoids source builds; --prefer-binary is a lighter
    # hint that still allows source if no wheel exists.
    ./venv/bin/python -m pip install -q --prefer-binary $DEPS
    if [[ $? -ne 0 ]]; then
        log_warn "Silent pip install failed — retrying with output..."
        ./venv/bin/python -m pip install --prefer-binary $DEPS \
            || fatal "Dependency installation failed. See output above."
    fi
fi
log_ok "All dependencies installed"

log_info "Running import verification checks..."
./venv/bin/python -c "import jwt" \
    || fatal "PyJWT import failed after install."
./venv/bin/python -c "from cryptography.hazmat.primitives.asymmetric import rsa" \
    || fatal "cryptography import failed after install."
./venv/bin/python -c "from pyarmor_runtime_000000 import __pyarmor__" \
    || fatal "PyArmor runtime import failed.\nVerify pyarmor_runtime.so is the linux.x86_64 build for Python 3.11."
log_ok "All critical imports verified (jwt, cryptography, pyarmor_runtime)"

# ==================================================
# STEP 6 — LICENCE VALIDATION
# ==================================================
echo -e "\n${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}ENTER YOUR LICENCE KEY${NC}${CYAN}                         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo    "  Paste your RS256 licence token below."
echo    "  Press ENTER then CTRL+D when done:"
echo

LIC_KEY=$(cat </dev/tty | tr -d '[:space:]')
[[ -z "$LIC_KEY" ]] && fatal "No licence key was entered."
echo -n "$LIC_KEY" > license.key

log_info "Verifying licence signature against hardware ID..."

# license.py has no __main__ block — must call function explicitly
./venv/bin/python -c "
from license import verify_and_load_license
verify_and_load_license()
"
if [[ $? -ne 0 ]]; then
    echo -e "\n${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  LICENCE VALIDATION FAILED                       ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "${RED}  The key may be invalid, expired, or bound to a${NC}"
    echo -e "${RED}  different server's hardware ID.${NC}"
    sudo rm -rf /opt/logistics_bot
    rm -f "$ZIP_PATH"
    exit 1
fi
log_ok "Licence verified successfully"

# ==================================================
# STEP 7 — API CONFIGURATION
# ==================================================
echo -e "\n${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}API CONFIGURATION${NC}${CYAN}                              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

read -rp "  Enter your Telegram Bot Token: " TG_TOKEN </dev/tty
read -rp "  Enter your Mapbox API Token:   " MB_TOKEN </dev/tty

[[ -z "$TG_TOKEN" ]] && fatal "Telegram token cannot be empty."
[[ -z "$MB_TOKEN" ]] && fatal "Mapbox token cannot be empty."

printf "TELEGRAM_TOKEN=%s\nMAPBOX_TOKEN=%s\n" "$TG_TOKEN" "$MB_TOKEN" > .env
log_ok ".env file written"

# ==================================================
# STEP 8 — DASHBOARD COMMAND & SYSTEMD SERVICE
# ==================================================
log_section "6/6" "Setting up service and dashboard"

sudo tee /usr/local/bin/dashboard > /dev/null << 'DASHBOARD_EOF'
#!/bin/bash
cd /opt/logistics_bot
./venv/bin/python dashboard.py
DASHBOARD_EOF
sudo chmod +x /usr/local/bin/dashboard
log_ok "dashboard command installed"

sudo tee /etc/systemd/system/logistics_bot.service > /dev/null << 'SERVICE_EOF'
[Unit]
Description=Logistics Engine Telegram Bot
After=network.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=/opt/logistics_bot
ExecStart=/opt/logistics_bot/venv/bin/python main.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable logistics_bot > /dev/null 2>&1
sudo systemctl start logistics_bot
log_info "systemd service start requested (status verified below)"

rm -f "$ZIP_PATH"

# ==================================================
# FINAL STATUS
# ==================================================
sleep 4
if sudo systemctl is-active --quiet logistics_bot; then
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}INSTALLATION COMPLETE${NC}${CYAN}                         ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} Bot service is running                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} Licence bound to this server hardware ID       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Live dashboard : ${GREEN}dashboard${NC}                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Service logs   : ${GREEN}journalctl -u logistics_bot -f${NC}  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Stop service   : ${GREEN}systemctl stop logistics_bot${NC}    ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
else
    echo -e "\n${YELLOW}Installation finished but service did not start.${NC}"
    echo -e "Diagnose with: ${GREEN}journalctl -u logistics_bot -n 50 --no-pager${NC}"
    exit 1
fi
