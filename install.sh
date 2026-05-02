#!/bin/bash
# ==================================================
# LOGISTICS ENGINE — INSTALLER
# Fixes applied:
#   [1] cryptography built from source to match server OpenSSL (prevents segfault)
#   [2] License verification actually invoked (was silently skipped before)
#   [3] Python 3.11 enforced for PyArmor .so ABI compatibility
#   [4] PyArmor runtime directory verified after unzip
#   [5] Zip nested-folder flattening handled automatically
# ==================================================

set -euo pipefail

# --- Terminal Colors ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Helper: print a fatal error and exit cleanly ---
fatal() {
    echo -e "\n${RED}==================================================${NC}"
    echo -e "${RED}FATAL: $1${NC}"
    echo -e "${RED}==================================================${NC}"
    # Clean up install directory if it was created
    if [[ -d /opt/logistics_bot ]]; then
        echo -e "${YELLOW}Removing incomplete installation...${NC}"
        sudo rm -rf /opt/logistics_bot
    fi
    rm -f "$ZIP_PATH" 2>/dev/null || true
    exit 1
}

echo -e "${CYAN}==================================================${NC}"
echo -e "${GREEN} LOGISTICS ENGINE — INSTALLER${NC}"
echo -e "${CYAN}==================================================${NC}"

ZIP_URL="https://github.com/pami303/Logistics-Core/raw/refs/heads/main/core.zip"
ZIP_PATH="$(pwd)/core.zip"

# ==================================================
# 1. SYSTEM PACKAGES
# ==================================================
echo -e "\n${YELLOW}[1/6] Installing system dependencies...${NC}"

sudo apt-get update -y -q > /dev/null 2>&1

# python3.11 + dev headers required for PyArmor .so ABI compatibility.
# cryptography build deps (libssl-dev, libffi-dev, build-essential) required
# to compile from source and match the server's actual OpenSSL version.
sudo apt-get install -y -q \
    unzip wget \
    python3.11 python3.11-venv python3.11-dev \
    python3-pip \
    build-essential libssl-dev libffi-dev \
    > /dev/null 2>&1 || true

# Verify Python 3.11 is available — PyArmor's pyarmor_runtime.so is compiled
# against the CPython 3.11 ABI. Running it under 3.10 or 3.12 will segfault
# or produce an ImportError.
PY311=$(command -v python3.11 2>/dev/null || true)
if [[ -z "$PY311" ]]; then
    echo -e "${YELLOW}Python 3.11 not found in apt, trying deadsnakes PPA...${NC}"
    sudo apt-get install -y -q software-properties-common > /dev/null 2>&1
    sudo add-apt-repository -y ppa:deadsnakes/ppa > /dev/null 2>&1
    sudo apt-get update -y -q > /dev/null 2>&1
    sudo apt-get install -y -q python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1
    PY311=$(command -v python3.11 2>/dev/null || true)
fi

[[ -z "$PY311" ]] && fatal "Could not install Python 3.11. PyArmor runtime requires exactly Python 3.11."

echo -e "${GREEN}  ✓ Python 3.11 found at: $PY311${NC}"

# ==================================================
# 2. DOWNLOAD & UNPACK
# ==================================================
echo -e "\n${YELLOW}[2/6] Downloading application files...${NC}"

wget -qO "$ZIP_PATH" "$ZIP_URL" \
    || fatal "Download failed. Check ZIP_URL and network connectivity."

sudo rm -rf /opt/logistics_bot
sudo mkdir -p /opt/logistics_bot

# Handle zips that have a single top-level subdirectory (e.g. core/) vs
# zips that have files at the root level — both layouts work correctly.
TMP_UNZIP="$(mktemp -d)"
sudo unzip -q "$ZIP_PATH" -d "$TMP_UNZIP" \
    || fatal "Failed to unzip core.zip."

# Count top-level entries in the zip
TOP_LEVEL_COUNT=$(ls "$TMP_UNZIP" | wc -l)
TOP_LEVEL_ENTRY=$(ls "$TMP_UNZIP" | head -1)

if [[ "$TOP_LEVEL_COUNT" -eq 1 && -d "$TMP_UNZIP/$TOP_LEVEL_ENTRY" ]]; then
    # Zip has a single wrapper folder — flatten it
    sudo cp -r "$TMP_UNZIP/$TOP_LEVEL_ENTRY/." /opt/logistics_bot/
else
    # Files are at the root of the zip
    sudo cp -r "$TMP_UNZIP/." /opt/logistics_bot/
fi
sudo rm -rf "$TMP_UNZIP"
cd /opt/logistics_bot || fatal "Could not enter /opt/logistics_bot"

# ==================================================
# 3. PYARMOR RUNTIME INTEGRITY CHECK
# ==================================================
# The obfuscated scripts all begin with:
#   from pyarmor_runtime_000000 import __pyarmor__
# If this directory or the .so is missing, every script will crash immediately.
echo -e "\n${YELLOW}[3/6] Verifying PyArmor runtime...${NC}"

PYARMOR_DIR="pyarmor_runtime_000000"
PYARMOR_SO="$PYARMOR_DIR/pyarmor_runtime.so"

if [[ ! -d "$PYARMOR_DIR" ]]; then
    fatal "PyArmor runtime directory '$PYARMOR_DIR' not found in the zip.\n       Regenerate the zip from your PyArmor 'dist/' output folder which must include this directory."
fi

if [[ ! -f "$PYARMOR_SO" ]]; then
    fatal "PyArmor runtime library '$PYARMOR_SO' is missing.\n       Re-run: pyarmor gen -O dist --platform linux.x86_64 .\n       Then re-zip the entire dist/ folder contents."
fi

echo -e "${GREEN}  ✓ PyArmor runtime present: $PYARMOR_SO${NC}"

# Verify the .so is a valid ELF binary for linux x86_64 (not a Windows DLL)
FILE_OUT=$(file "$PYARMOR_SO" 2>/dev/null || true)
if echo "$FILE_OUT" | grep -q "ELF 64-bit"; then
    echo -e "${GREEN}  ✓ Runtime is a valid Linux x86_64 ELF binary${NC}"
elif echo "$FILE_OUT" | grep -qi "PE32\|DLL\|MS Windows"; then
    fatal "pyarmor_runtime.so is a Windows DLL, not a Linux binary.\n       You must regenerate with: pyarmor gen -O dist --platform linux.x86_64 ."
else
    echo -e "${YELLOW}  ⚠ Could not confirm ELF type ('file' tool unavailable), proceeding anyway.${NC}"
fi

# ==================================================
# 4. ISOLATED PYTHON 3.11 ENVIRONMENT
# ==================================================
echo -e "\n${YELLOW}[4/6] Creating isolated Python 3.11 environment...${NC}"

# Use python3.11 explicitly — do NOT use the system default python3.
# PyArmor's runtime .so is ABI-locked to the exact CPython version it was
# compiled against (3.11). Using 3.10 or 3.12 causes a segfault or ImportError.
python3.11 -m venv venv

echo -e "     Upgrading pip, setuptools, wheel..."
./venv/bin/python -m pip install -q --upgrade pip setuptools wheel

echo -e "     Building cryptography from source (prevents OpenSSL segfault)..."
# cffi must be installed first — cryptography's build system requires it.
# --no-binary cryptography forces compilation against the server's actual
# libssl.so instead of using a pre-built wheel that may link a different version.
./venv/bin/python -m pip install -q cffi
./venv/bin/python -m pip install -q --no-binary cryptography cryptography

echo -e "     Installing remaining dependencies..."
./venv/bin/python -m pip install -q \
    python-telegram-bot \
    httpx \
    python-dotenv \
    aiofiles \
    rich \
    "PyJWT[crypto]" \
    psutil

echo -e "${GREEN}  ✓ All dependencies installed${NC}"

# Quick sanity check: confirm PyJWT + cryptography are importable
./venv/bin/python -c "import jwt; jwt.decode" 2>/dev/null \
    || fatal "PyJWT import failed after installation. Check pip output above."

./venv/bin/python -c "from cryptography.hazmat.primitives.asymmetric import rsa" 2>/dev/null \
    || fatal "cryptography import failed. The source build may have encountered an error."

echo -e "${GREEN}  ✓ PyJWT + cryptography import check passed${NC}"

# ==================================================
# 5. LICENCE VALIDATION
# ==================================================
echo -e "\n${CYAN}==================================================${NC}"
echo -e "${GREEN} ENTER YOUR LICENCE KEY${NC}"
echo -e "${CYAN}==================================================${NC}"
echo "Paste your RS256 licence token below."
echo "(Press ENTER, then CTRL+D when finished):"

# Read from /dev/tty explicitly so this works when piped via curl | bash
LIC_KEY=$(cat </dev/tty | tr -d '[:space:]')
[[ -z "$LIC_KEY" ]] && fatal "No licence key entered."
echo -n "$LIC_KEY" > license.key

echo -e "\n${YELLOW}Verifying licence signature...${NC}"

# BUG FIX: The original line was `./venv/bin/python license.py`
# license.py has NO `if __name__ == '__main__'` block — running it as a
# script only defines functions and exits 0 silently. The licence was
# never actually checked. We must call verify_and_load_license() explicitly.
./venv/bin/python -c "
from license import verify_and_load_license
verify_and_load_license()
" || {
    echo -e "\n${RED}==================================================${NC}"
    echo -e "${RED}Licence validation failed.${NC}"
    echo -e "${RED}The key may be invalid, expired, or bound to a different server.${NC}"
    echo -e "${YELLOW}Removing downloaded files...${NC}"
    cd /opt
    sudo rm -rf logistics_bot
    rm -f "$ZIP_PATH"
    echo -e "${RED}Installation aborted.${NC}"
    echo -e "${RED}==================================================${NC}"
    exit 1
}

# ==================================================
# 6. API CONFIGURATION
# ==================================================
echo -e "\n${CYAN}==================================================${NC}"
echo -e "${GREEN}Licence verified. Proceeding to configuration.${NC}"
echo -e "${CYAN}==================================================${NC}"

read -rp "Enter your Telegram Bot Token: " TG_TOKEN </dev/tty
read -rp "Enter your Mapbox API Token:   " MB_TOKEN </dev/tty

[[ -z "$TG_TOKEN" ]] && fatal "Telegram token cannot be empty."
[[ -z "$MB_TOKEN" ]] && fatal "Mapbox token cannot be empty."

printf "TELEGRAM_TOKEN=%s\nMAPBOX_TOKEN=%s\n" "$TG_TOKEN" "$MB_TOKEN" > .env

# ==================================================
# 7. SYSTEM & DASHBOARD SETUP
# ==================================================
echo -e "\n${YELLOW}[5/6] Setting up the terminal dashboard command...${NC}"
sudo tee /usr/local/bin/dashboard > /dev/null << 'EOL'
#!/bin/bash
cd /opt/logistics_bot
./venv/bin/python dashboard.py
EOL
sudo chmod +x /usr/local/bin/dashboard

echo -e "${YELLOW}[6/6] Configuring and starting background service...${NC}"
sudo tee /etc/systemd/system/logistics_bot.service > /dev/null << 'EOL'
[Unit]
Description=Logistics Engine Telegram Bot
After=network.target

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
EOL

sudo systemctl daemon-reload
sudo systemctl enable logistics_bot > /dev/null 2>&1
sudo systemctl start logistics_bot

# Cleanup
rm -f "$ZIP_PATH"

# Final status check
sleep 2
if sudo systemctl is-active --quiet logistics_bot; then
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${GREEN} INSTALLATION COMPLETE${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "  ${GREEN}✓${NC} Service is running (logistics_bot.service)"
    echo -e "  ${GREEN}✓${NC} Installation bound to this server's hardware ID"
    echo -e ""
    echo -e "  Monitor live:   ${GREEN}dashboard${NC}"
    echo -e "  Service logs:   ${GREEN}journalctl -u logistics_bot -f${NC}"
    echo -e "  Stop service:   ${GREEN}systemctl stop logistics_bot${NC}"
    echo -e "${CYAN}==================================================${NC}"
else
    echo -e "\n${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}Installation complete but service failed to start.${NC}"
    echo -e "Check logs with: ${GREEN}journalctl -u logistics_bot -n 50${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    exit 1
fi
