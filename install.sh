#!/bin/bash

# --- Terminal Colors ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}==================================================${NC}"
echo -e "${GREEN} LOGISTICS ENGINE — INSTALLER${NC}"
echo -e "${CYAN}==================================================${NC}"

# ==================================================
# 1. DOWNLOAD & PREPARE FILES
# ==================================================
echo -e "\n${YELLOW}[1/5] Downloading application files...${NC}"

# Set your GitHub raw ZIP link below
ZIP_URL="https://github.com/pami303/Logistics-Core/raw/refs/heads/main/core.zip"
ZIP_PATH="$(pwd)/core.zip"

wget -qO "$ZIP_PATH" "$ZIP_URL" || { echo -e "${RED}Download failed. Please check the ZIP_URL and your network connection.${NC}"; exit 1; }

sudo apt update -y -q > /dev/null 2>&1
sudo apt install unzip python3-pip python3-venv -y -q > /dev/null 2>&1

sudo rm -rf /opt/logistics_bot
sudo unzip -q "$ZIP_PATH" -d /opt/logistics_bot
cd /opt/logistics_bot || exit

# ==================================================
# 2. ISOLATED PYTHON ENVIRONMENT
# ==================================================
echo -e "${YELLOW}[2/5] Creating isolated Python environment...${NC}"
python3 -m venv venv
source venv/bin/activate
pip install -q python-telegram-bot httpx python-dotenv aiofiles PyJWT cryptography psutil rich

# ==================================================
# 3. LICENCE VALIDATION
# ==================================================
echo -e "\n${CYAN}==================================================${NC}"
echo -e "${GREEN} ENTER YOUR LICENCE KEY${NC}"
echo -e "${CYAN}==================================================${NC}"
echo "Paste your RS256 licence token below."
echo "(Press ENTER, then press CTRL+D when finished):"
LIC_KEY=$(cat)
echo "$LIC_KEY" > license.key

echo -e "\n${YELLOW}Verifying licence signature...${NC}"

python3 license.py

if [ $? -ne 0 ]; then
    echo -e "\n${RED}==================================================${NC}"
    echo -e "${RED}Licence validation failed. The key may be invalid, corrupted, or expired.${NC}"
    echo -e "${YELLOW}Removing downloaded files...${NC}"
    cd /opt
    sudo rm -rf logistics_bot
    rm -f "$ZIP_PATH"
    echo -e "${RED}Installation aborted.${NC}"
    echo -e "${RED}==================================================${NC}"
    exit 1
fi

# ==================================================
# 4. API CONFIGURATION
# ==================================================
echo -e "\n${CYAN}==================================================${NC}"
echo -e "${GREEN}Licence verified. Proceeding to configuration.${NC}"
echo -e "${CYAN}==================================================${NC}"

read -p "Enter your Telegram Bot Token: " TG_TOKEN
read -p "Enter your Mapbox API Token:   " MB_TOKEN

echo "TELEGRAM_TOKEN=$TG_TOKEN" > .env
echo "MAPBOX_TOKEN=$MB_TOKEN" >> .env

# ==================================================
# 5. SYSTEM & DASHBOARD SETUP
# ==================================================
echo -e "\n${YELLOW}[3/5] Setting up the terminal dashboard...${NC}"
sudo bash -c "cat > /usr/local/bin/dashboard" << EOL
#!/bin/bash
cd /opt/logistics_bot
source venv/bin/activate
python3 dashboard.py
EOL
sudo chmod +x /usr/local/bin/dashboard

echo -e "${YELLOW}[4/5] Configuring background service...${NC}"
sudo bash -c "cat > /etc/systemd/system/logistics_bot.service" << EOL
[Unit]
Description=Logistics Engine Telegram Bot
After=network.target

[Service]
User=root
WorkingDirectory=/opt/logistics_bot
ExecStart=/opt/logistics_bot/venv/bin/python3 main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
echo -e "${YELLOW}[5/5] Starting the service...${NC}"
sudo systemctl enable logistics_bot > /dev/null 2>&1
sudo systemctl start logistics_bot

# Cleanup
rm -f "$ZIP_PATH"

echo -e "\n${CYAN}==================================================${NC}"
echo -e "${GREEN} INSTALLATION COMPLETE${NC}"
echo -e "${CYAN}==================================================${NC}"
echo -e "The installation is bound to this server's hardware ID."
echo -e "The Telegram bot is now running in the background."
echo -e "To open the monitoring dashboard at any time, run: ${GREEN}dashboard${NC}"
echo -e "${CYAN}==================================================${NC}"
