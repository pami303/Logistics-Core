#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  LOGISTICS ENGINE — INSTALLER v4  (ULTIMATE EDITION - UV POWERED)
#  Target: Ubuntu 24.04 LTS (noble) — also works on 22.04 (jammy)
#
#  Research sources applied:
#  • uv installer: UV_INSTALL_DIR for system-wide install to /usr/local/bin
#  • uv python: Fetches pre-compiled, standalone Python binaries
#  • uv pip environments: VIRTUAL_ENV for non-.venv directories
#  • Bash word-splitting: mapfile+find instead of ls|wc/head
#  • PYTHONUNBUFFERED=1 in systemd for real-time log output
# ══════════════════════════════════════════════════════════════════

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m';   BOLD='\033[1m';    NC='\033[0m'

ZIP_URL="https://github.com/pami303/Logistics-Core/raw/refs/heads/main/core.zip"
ZIP_PATH="/tmp/core.zip"
INSTALL_DIR="/opt/logistics_bot"

log_info()    { echo -e "${CYAN}  →${NC} $1"; }
log_ok()      { echo -e "${GREEN}  ✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}  ⚠${NC} $1"; }
log_section() { echo -e "\n${BOLD}${YELLOW}[$1]${NC} $2"; }

fatal() {
    echo -e "\n${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  FATAL ERROR                                     ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "${RED}  $1${NC}\n"
    [[ -d "$INSTALL_DIR" ]] && { log_warn "Cleaning up $INSTALL_DIR..."; rm -rf "$INSTALL_DIR"; }
    rm -f "$ZIP_PATH" 2>/dev/null
    exit 1
}

echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}LOGISTICS ENGINE — INSTALLER v4${NC}${CYAN}                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

# ══════════════════════════════════════════════════════════════════
#  STEP 1 — BASE PACKAGES
# ══════════════════════════════════════════════════════════════════
log_section "1/6" "Installing base system packages"

apt-get -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=5 -o Acquire::https::Timeout=5 -o Acquire::Retries=1 update -y -q > /dev/null 2>&1 \
    || log_warn "apt update had warnings (non-fatal)"

BASE="unzip wget curl ca-certificates software-properties-common lsb-release"
log_info "Installing: $BASE"
if ! apt-get -o Acquire::ForceIPv4=true install -y -q $BASE > /dev/null 2>&1; then
    log_warn "Quiet install failed — retrying with output:"
    apt-get -o Acquire::ForceIPv4=true install -y $BASE \
        || fatal "Cannot install base packages.\nCheck your apt sources and network."
fi
log_ok "Base packages ready"

# ══════════════════════════════════════════════════════════════════
#  STEP 2 — PYTHON 3.11 VIA ASTRAL UV
#  Bypasses Ubuntu repositories entirely for guaranteed fast install.
# ══════════════════════════════════════════════════════════════════
log_section "2/6" "Provisioning Python 3.11 via Astral uv"

UV_BIN=$(command -v uv 2>/dev/null || true)
if [[ -z "$UV_BIN" ]]; then
    log_info "Installing uv to /usr/local/bin..."
    curl -fsSL --max-time 30 https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin sh > /dev/null 2>&1 || true
    UV_BIN=$(command -v uv 2>/dev/null || true)
    [[ -z "$UV_BIN" ]] && fatal "uv package manager install failed. Check network."
fi
log_ok "uv installed: $UV_BIN"

log_info "Fetching standalone Python 3.11..."
if ! "$UV_BIN" python install 3.11 > /dev/null 2>&1; then
    log_warn "uv quiet python install failed — retrying with output:"
    "$UV_BIN" python install 3.11 || fatal "Failed to download Python 3.11."
fi

PY311=$("$UV_BIN" python find 3.11 2>/dev/null || true)
[[ -z "$PY311" ]] && fatal "Python 3.11 installed but uv cannot locate it."

log_ok "Python 3.11 ready: $PY311"

# ══════════════════════════════════════════════════════════════════
#  STEP 3 — DOWNLOAD & UNPACK
# ══════════════════════════════════════════════════════════════════
log_section "3/6" "Downloading application files"

log_info "Fetching core.zip from GitHub..."
wget -q --tries=3 --timeout=60 -O "$ZIP_PATH" "$ZIP_URL" \
    || fatal "Download failed.\nURL: $ZIP_URL\nCheck network and repo availability."
log_ok "Download complete ($(du -sh "$ZIP_PATH" | cut -f1))"

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

TMP_UNZIP=$(mktemp -d)
log_info "Extracting..."
unzip -q "$ZIP_PATH" -d "$TMP_UNZIP" \
    || fatal "Extraction failed. core.zip may be corrupted or truncated."

# Safe flatten using mapfile+find — immune to filenames with spaces
mapfile -t TOP_ENTRIES < <(find "$TMP_UNZIP" -mindepth 1 -maxdepth 1)
TOP_COUNT=${#TOP_ENTRIES[@]}
TOP_ENTRY="${TOP_ENTRIES[0]:-}"

if [[ "$TOP_COUNT" -eq 1 && -d "$TOP_ENTRY" ]]; then
    FOLDER_NAME=$(basename "$TOP_ENTRY")
    log_info "Flattening single wrapper folder: '$FOLDER_NAME'"
    cp -r "$TOP_ENTRY/." "$INSTALL_DIR/"
else
    cp -r "$TMP_UNZIP/." "$INSTALL_DIR/"
fi

rm -rf "$TMP_UNZIP"
cd "$INSTALL_DIR" || fatal "Cannot enter $INSTALL_DIR"
log_ok "Files in $INSTALL_DIR"

# ══════════════════════════════════════════════════════════════════
#  STEP 4 — PYARMOR RUNTIME INTEGRITY CHECK
# ══════════════════════════════════════════════════════════════════
log_section "4/6" "Verifying PyArmor runtime"

PA_DIR="pyarmor_runtime_000000"
PA_INIT="$PA_DIR/__init__.py"
PA_SO="$PA_DIR/pyarmor_runtime.so"

[[ ! -d "$PA_DIR" ]] && fatal \
    "PyArmor runtime directory '$PA_DIR' not found.\nRe-zip your PyArmor dist/ output."
[[ ! -f "$PA_INIT" ]] && fatal \
    "'$PA_INIT' missing — Python won't treat the dir as a package."
[[ ! -f "$PA_SO"   ]] && fatal \
    "'$PA_SO' missing.\nRun: pyarmor gen -O dist --platform linux.x86_64 .\nThen re-zip dist/ contents."

log_ok "PyArmor runtime files present"

if command -v file > /dev/null 2>&1; then
    FILE_OUT=$(file "$PA_SO")
    if echo "$FILE_OUT" | grep -qi "PE32\|PE64\|MS Windows\|DLL"; then
        fatal "'$PA_SO' is a Windows binary — not usable on Linux.\nRe-run: pyarmor gen -O dist --platform linux.x86_64 ."
    elif echo "$FILE_OUT" | grep -q "ELF 64-bit"; then
        log_ok "Runtime confirmed as Linux x86_64 ELF binary"
    else
        log_warn "Cannot confirm ELF type — proceeding anyway: $FILE_OUT"
    fi
fi

# ══════════════════════════════════════════════════════════════════
#  STEP 5 — VIRTUAL ENVIRONMENT & DEPENDENCIES
# ══════════════════════════════════════════════════════════════════
log_section "5/6" "Creating Python virtual environment"

log_info "Creating venv..."
"$UV_BIN" venv --python 3.11 venv > /dev/null 2>&1 \
    || fatal "venv creation failed."
log_ok "Virtual environment ready"

DEPS=(
    "cryptography"
    "python-telegram-bot"
    "httpx"
    "python-dotenv"
    "aiofiles"
    "rich"
    "PyJWT[crypto]"
    "psutil"
)

log_info "Installing Python dependencies..."
if ! VIRTUAL_ENV="$(pwd)/venv" "$UV_BIN" pip install "${DEPS[@]}" > /dev/null 2>&1; then
    log_warn "uv quiet install failed — retrying with output:"
    VIRTUAL_ENV="$(pwd)/venv" "$UV_BIN" pip install "${DEPS[@]}" \
        || fatal "Dependency installation failed. See output above."
fi
log_ok "All dependencies installed"

log_info "Verifying critical imports..."
./venv/bin/python -c "import jwt" \
    || fatal "PyJWT import failed after install."
./venv/bin/python -c "from cryptography.hazmat.primitives.asymmetric import rsa" \
    || fatal "cryptography import failed after install."
./venv/bin/python -c "from pyarmor_runtime_000000 import __pyarmor__" \
    || fatal "PyArmor runtime import failed.\nVerify pyarmor_runtime.so is the linux.x86_64 build for Python 3.11."
log_ok "Imports verified  (jwt ✓  cryptography ✓  pyarmor_runtime ✓)"

# ══════════════════════════════════════════════════════════════════
#  STEP 6 — LICENCE VALIDATION
# ══════════════════════════════════════════════════════════════════
echo -e "\n${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}ENTER YOUR LICENCE KEY${NC}${CYAN}                         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo    "  Paste your RS256 licence token below."
echo    "  Press ENTER then CTRL+D when done:"
echo

LIC_KEY=$(cat </dev/tty | tr -d '[:space:]')
[[ -z "$LIC_KEY" ]] && fatal "No licence key entered."
echo -n "$LIC_KEY" > license.key

log_info "Verifying licence signature against hardware ID..."
./venv/bin/python -c "
from license import verify_and_load_license
verify_and_load_license()
"
if [[ $? -ne 0 ]]; then
    echo -e "\n${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  LICENCE VALIDATION FAILED                       ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "${RED}  Key invalid, expired, or bound to a different server.${NC}"
    rm -rf "$INSTALL_DIR"
    rm -f  "$ZIP_PATH"
    exit 1
fi
log_ok "Licence verified successfully"

# ══════════════════════════════════════════════════════════════════
#  STEP 7 — API TOKENS
# ══════════════════════════════════════════════════════════════════
echo -e "\n${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}API CONFIGURATION${NC}${CYAN}                              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

read -rp "  Enter your Telegram Bot Token: " TG_TOKEN </dev/tty
read -rp "  Enter your Mapbox API Token:   " MB_TOKEN </dev/tty

[[ -z "$TG_TOKEN" ]] && fatal "Telegram token cannot be empty."
[[ -z "$MB_TOKEN" ]] && fatal "Mapbox token cannot be empty."

printf "TELEGRAM_TOKEN=%s\nMAPBOX_TOKEN=%s\n" "$TG_TOKEN" "$MB_TOKEN" > .env
log_ok ".env written"

# ══════════════════════════════════════════════════════════════════
#  STEP 8 — SYSTEMD SERVICE + DASHBOARD COMMAND
# ══════════════════════════════════════════════════════════════════
log_section "6/6" "Installing service and dashboard command"

tee /usr/local/bin/dashboard > /dev/null << 'DASHBOARD_EOF'
#!/bin/bash
cd /opt/logistics_bot
exec ./venv/bin/python dashboard.py
DASHBOARD_EOF
chmod +x /usr/local/bin/dashboard
log_ok "dashboard command installed"

tee /etc/systemd/system/logistics_bot.service > /dev/null << 'SERVICE_EOF'
[Unit]
Description=Logistics Engine Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=/opt/logistics_bot
ExecStart=/opt/logistics_bot/venv/bin/python main.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable logistics_bot > /dev/null 2>&1
systemctl start  logistics_bot
log_info "Service start requested — verifying in 4 seconds..."

rm -f "$ZIP_PATH"

sleep 4
if systemctl is-active --quiet logistics_bot; then
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
    echo -e "\n${YELLOW}  Installation finished but service did not start cleanly.${NC}"
    echo -e "  Diagnose: ${GREEN}journalctl -u logistics_bot -n 50 --no-pager${NC}"
    exit 1
fi
