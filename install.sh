#!/bin/bash
# ==================================================
# LOGISTICS ENGINE — INSTALLER v2
# Robust edition: every dependency has a fallback chain,
# errors are visible, nothing fails silently.
# ==================================================

# NOTE: We intentionally do NOT use `set -e` here.
# Every command is checked explicitly so failures are
# caught with a clear message instead of a silent exit.

# --- Terminal Colors ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ZIP_URL="https://github.com/pami303/Logistics-Core/raw/refs/heads/main/core.zip"
ZIP_PATH="/tmp/core.zip"

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

sudo apt-get update -y -q > /dev/null 2>&1 || log_warn "apt update had warnings — continuing anyway"

BASE_PKGS="unzip wget curl gnupg ca-certificates software-properties-common build-essential libssl-dev libffi-dev python3-pip"

log_info "Installing base packages..."
sudo apt-get install -y -q $BASE_PKGS > /dev/null 2>&1
if [[ $? -ne 0 ]]; then
    log_warn "Silent install had issues, retrying with output visible..."
    sudo apt-get install -y $BASE_PKGS || fatal "Could not install base packages. Check your apt sources."
fi
log_ok "Base packages ready"

# ==================================================
# STEP 2 — PYTHON 3.11 (3-method fallback chain)
# ==================================================
log_section "2/6" "Ensuring Python 3.11 is available"

PY311=$(command -v python3.11 2>/dev/null || true)

if [[ -n "$PY311" ]]; then
    log_ok "Python 3.11 already installed: $PY311"
else
    # ---- Method A: standard apt (works on Ubuntu 22.04) ----
    log_info "Method A: trying standard apt repos..."
    sudo apt-get install -y -q python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1
    PY311=$(command -v python3.11 2>/dev/null || true)

    if [[ -z "$PY311" ]]; then
        # ---- Method B: deadsnakes PPA (Ubuntu 20.04 / 24.04) ----
        # Uses HTTPS key fetch from Launchpad — avoids keyserver timeouts
        # which are common on fresh cloud instances.
        log_info "Method B: adding deadsnakes PPA via HTTPS key fetch..."

        sudo apt-get install -y -q gpg curl > /dev/null 2>&1 || true

        CODENAME=$(lsb_release -sc 2>/dev/null || echo "jammy")

        # Fetch GPG key over HTTPS (reliable, no keyserver dependency)
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" \
            | sudo gpg --dearmor -o /usr/share/keyrings/deadsnakes.gpg 2>/dev/null

        if [[ $? -eq 0 && -s /usr/share/keyrings/deadsnakes.gpg ]]; then
            echo "deb [signed-by=/usr/share/keyrings/deadsnakes.gpg] https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu $CODENAME main" \
                | sudo tee /etc/apt/sources.list.d/deadsnakes.list > /dev/null
            sudo apt-get update -y -q > /dev/null 2>&1
            sudo apt-get install -y -q python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1
            PY311=$(command -v python3.11 2>/dev/null || true)
        fi

        if [[ -z "$PY311" ]]; then
            # Sub-fallback: classic add-apt-repository
            log_warn "HTTPS key fetch failed — trying add-apt-repository..."
            sudo add-apt-repository -y ppa:deadsnakes/ppa > /dev/null 2>&1 || true
            sudo apt-get update -y -q > /dev/null 2>&1
            sudo apt-get install -y -q python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1
            PY311=$(command -v python3.11 2>/dev/null || true)
        fi
    fi

    if [[ -z "$PY311" ]]; then
        # ---- Method C: compile from source (~8 min, always works) ----
        log_warn "PPA methods failed. Compiling Python 3.11 from source..."
        log_warn "This will take approximately 8-10 minutes. Please wait..."

        sudo apt-get install -y -q \
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
        ./configure --enable-optimizations --prefix=/usr/local > /dev/null 2>&1 \
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

# Ensure venv module is available
if ! python3.11 -m venv --help > /dev/null 2>&1; then
    log_info "Installing python3.11-venv module..."
    sudo apt-get install -y -q python3.11-venv > /dev/null 2>&1 || \
    sudo apt-get install -y -q python3-venv > /dev/null 2>&1 || true
fi

PY_VERSION=$(python3.11 --version 2>&1)
log_ok "Python 3.11 ready: $PY_VERSION"

# ==================================================
# STEP 3 — DOWNLOAD & UNPACK
# ==================================================
log_section "3/6" "Downloading application files"

log_info "Fetching core.zip from GitHub..."
wget -q -O "$ZIP_PATH" "$ZIP_URL"
[[ $? -ne 0 ]] && fatal "Download failed.\nURL: $ZIP_URL\nCheck network and GitHub repo availability."
log_ok "Download complete"

sudo rm -rf /opt/logistics_bot
sudo mkdir -p /opt/logistics_bot

TMP_UNZIP=$(mktemp -d)
log_info "Extracting..."
sudo unzip -q "$ZIP_PATH" -d "$TMP_UNZIP" \
    || fatal "Failed to extract core.zip. The file may be corrupted."

# Auto-flatten single wrapper folder if present
TOP_COUNT=$(ls "$TMP_UNZIP" | wc -l)
TOP_ENTRY=$(ls "$TMP_UNZIP" | head -1)

if [[ "$TOP_COUNT" -eq 1 && -d "$TMP_UNZIP/$TOP_ENTRY" ]]; then
    log_info "Detected wrapper folder '$TOP_ENTRY' — flattening..."
    sudo cp -r "$TMP_UNZIP/$TOP_ENTRY/." /opt/logistics_bot/
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
# ==================================================
log_section "5/6" "Creating Python 3.11 virtual environment"

log_info "Initialising venv..."
python3.11 -m venv venv \
    || fatal "python3.11 -m venv failed.\nTry: sudo apt-get install -y python3.11-venv"
log_ok "Virtual environment created"

log_info "Upgrading pip / setuptools / wheel..."
./venv/bin/python -m pip install -q --upgrade pip setuptools wheel \
    || fatal "pip upgrade failed"

log_info "Installing cffi (build dependency for cryptography)..."
./venv/bin/python -m pip install -q cffi \
    || fatal "cffi installation failed"

log_info "Compiling cryptography from source (prevents OpenSSL segfault — ~1 min)..."
./venv/bin/python -m pip install -q --no-binary cryptography cryptography
if [[ $? -ne 0 ]]; then
    log_warn "Source build failed — showing full output:"
    ./venv/bin/python -m pip install --no-binary cryptography cryptography
    fatal "cryptography source build failed. See output above."
fi
log_ok "cryptography built from source"

log_info "Installing application dependencies..."
./venv/bin/python -m pip install -q \
    "python-telegram-bot" \
    "httpx" \
    "python-dotenv" \
    "aiofiles" \
    "rich" \
    "PyJWT[crypto]" \
    "psutil"

if [[ $? -ne 0 ]]; then
    log_warn "Silent install failed — retrying with output visible..."
    ./venv/bin/python -m pip install \
        "python-telegram-bot" "httpx" "python-dotenv" \
        "aiofiles" "rich" "PyJWT[crypto]" "psutil" \
        || fatal "Dependency installation failed. See output above."
fi
log_ok "All dependencies installed"

log_info "Running import verification checks..."
./venv/bin/python -c "import jwt" \
    || fatal "PyJWT import failed after install."
./venv/bin/python -c "from cryptography.hazmat.primitives.asymmetric import rsa" \
    || fatal "cryptography import failed after source build."
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
log_ok "systemd service started"

rm -f "$ZIP_PATH"

# ==================================================
# FINAL STATUS
# ==================================================
sleep 2
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
