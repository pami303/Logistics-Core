#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  LOGISTICS ENGINE — INSTALLER v4  (ULTIMATE EDITION)
#  Target: Ubuntu 24.04 LTS (noble) — also works on 22.04 (jammy)
#
#  Research sources applied:
#  • Deadsnakes Launchpad PPA (launchpad.net/~deadsnakes)
#  • Ubuntu 24.04 GPG best-practice (/etc/apt/keyrings + signed-by)
#  • GnuPG manpage: --batch --yes prevent all interactive prompts
#  • gpg overwrite behaviour (lists.gnupg.org 2005/2020)
#  • uv installer: UV_INSTALL_DIR for system-wide install to /usr/local/bin
#  • uv pip environments: VIRTUAL_ENV for non-.venv directories
#  • PIPESTATUS: separate curl+gpg steps to catch curl failures
#  • mktemp -u: dry-run so gpg creates the file (no overwrite prompt)
#  • Bash word-splitting: mapfile+find instead of ls|wc/head
#  • apt NO_PUBKEY detection before attempting package install
#  • PYTHONUNBUFFERED=1 in systemd for real-time log output
# ══════════════════════════════════════════════════════════════════

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m';   BOLD='\033[1m';    NC='\033[0m'

ZIP_URL="https://github.com/pami303/Logistics-Core/raw/refs/heads/main/core.zip"
ZIP_PATH="/tmp/core.zip"
INSTALL_DIR="/opt/logistics_bot"

# Deadsnakes GPG fingerprint — stable since 2009, verified on Launchpad
DS_FP="F23C5A6CF475977595C89F51BA6932366A755776"
DS_GPG="/etc/apt/keyrings/deadsnakes.gpg"
DS_LIST="/etc/apt/sources.list.d/deadsnakes.list"

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

BASE="unzip wget curl gnupg2 ca-certificates software-properties-common lsb-release"
log_info "Installing: $BASE"
if ! apt-get -o Acquire::ForceIPv4=true install -y -q $BASE > /dev/null 2>&1; then
    log_warn "Quiet install failed — retrying with output:"
    apt-get -o Acquire::ForceIPv4=true install -y $BASE \
        || fatal "Cannot install base packages.\nCheck your apt sources and network."
fi
log_ok "Base packages ready"

# ══════════════════════════════════════════════════════════════════
#  STEP 2 — PYTHON 3.11
#
#  Ubuntu 24.04 (noble): python3.11 is NOT in universe.
#  Deadsnakes PPA is the only apt-based path.
#  Three methods tried in order, each with full fallback.
# ══════════════════════════════════════════════════════════════════
log_section "2/6" "Ensuring Python 3.11 is available"

PY311=$(command -v python3.11 2>/dev/null || true)

if [[ -n "$PY311" ]]; then
    log_ok "python3.11 already present: $PY311"
else

# ── Method A: plain apt (works on 22.04; nearly always a no-op on 24.04) ──
log_info "Method A: probing standard apt repos..."
apt-get -o Acquire::ForceIPv4=true install -y -q python3.11 python3.11-venv python3.11-dev \
    > /dev/null 2>&1 || true
PY311=$(command -v python3.11 2>/dev/null || true)

if [[ -z "$PY311" ]]; then

# ── Method B: deadsnakes PPA with /etc/apt/keyrings/ (Ubuntu 24.04 standard) ──
#
# Every line below addresses a specific confirmed failure mode:
#
#  FAILURE 1: stale .gpg / .list from previous run
#    → rm -f all deadsnakes files FIRST (clean slate before every attempt)
#
#  FAILURE 2: gpg prompts "File exists. Overwrite? (y/N)"
#    → Caused by mktemp creating the output file before gpg writes it.
#      Fix: mktemp -u (dry-run) — reserves unique name WITHOUT creating
#      the file, so gpg writes fresh with no overwrite prompt.
#    → Belt-and-suspenders: also pass --batch --yes to gpg.
#
#  FAILURE 3: curl failure masked by pipe (curl|gpg exit code = gpg's)
#    → Fix: two separate steps — curl to TMP_ASC, check exit code,
#      THEN gpg --dearmor < TMP_ASC. Each failure is independently visible.
#
#  FAILURE 4: apt-get update silently fails (key not trusted)
#    → Fix: capture full output, grep for NO_PUBKEY/BADSIG/not signed,
#      if found mark KEY_OK=false and fall through — don't attempt install.
#
#  FAILURE 5: "Unable to locate package python3.11" despite key success
#    → Root cause: apt-get update ran against a stale/unrefreshed index.
#      Fix: always run apt-get update AFTER writing the .list file,
#      and verify the update output confirms deadsnakes was accepted.
#
# ─────────────────────────────────────────────────────────────────
log_info "Method B: deadsnakes PPA (modern /etc/apt/keyrings/ approach)..."

CODENAME=$(lsb_release -sc 2>/dev/null \
    || grep -oP '(?<=VERSION_CODENAME=)\w+' /etc/os-release \
    || echo "noble")
log_info "  Detected codename: $CODENAME"

# Clean slate — remove every trace from any prior install attempt
mkdir -p /etc/apt/keyrings
rm -f "$DS_GPG" "$DS_LIST" 2>/dev/null || true
rm -f /etc/apt/trusted.gpg.d/deadsnakes*.gpg 2>/dev/null || true
rm -f /etc/apt/sources.list.d/deadsnakes*.list 2>/dev/null || true

# Try three key URLs in order of reliability for cloud VMs
#   URL 1: HTTPS REST  (port 443 — almost never blocked)
#   URL 2: HTTP port 80 (HKP port 11371 is often blocked on cloud VMs)
#   URL 3: keys.openpgp.org (independent infrastructure, good uptime)
KEY_OK=false
for KEY_URL in \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${DS_FP}" \
    "http://keyserver.ubuntu.com:80/pks/lookup?op=get&search=0x${DS_FP}" \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/${DS_FP}" \
    "https://launchpad.net/~deadsnakes/+archive/ubuntu/ppa/+archivekey"
do
    log_info "  Trying: $(echo "$KEY_URL" | cut -d/ -f1-3)..."

    # Step 1 — download armored key (curl exit code independently checked)
    TMP_ASC=$(mktemp)         # curl writes here as current user
    TMP_GPG=$(mktemp -u)      # DRY-RUN: unique name but file does NOT exist
                               # gpg will CREATE it → no "overwrite?" prompt

    CURL_RC=0
    curl -fsSL --max-time 20 "$KEY_URL" -o "$TMP_ASC" 2>/dev/null \
        || CURL_RC=$?

    if [[ $CURL_RC -ne 0 ]] || [[ ! -s "$TMP_ASC" ]]; then
        rm -f "$TMP_ASC"
        log_warn "  curl failed (rc=$CURL_RC) — trying next source"
        continue
    fi

    # Sanity-check: reject HTML error pages that keyservers return on failure.
    # These are non-empty so the -s size check passes, but gpg --dearmor on
    # HTML produces a corrupt or zero-byte output file.
    if head -c 100 "$TMP_ASC" | grep -qiE "<html|<!DOCTYPE|404|403|error"; then
        log_warn "  Server returned an error page, not a key — skipping"
        rm -f "$TMP_ASC"
        continue
    fi

    # Step 2 — dearmor: --batch --yes = fully non-interactive, never prompts
    GPG_RC=0
    gpg --batch --yes --dearmor -o "$TMP_GPG" < "$TMP_ASC" 2>/dev/null \
        || GPG_RC=$?
    rm -f "$TMP_ASC"

    if [[ $GPG_RC -ne 0 ]] || [[ ! -s "$TMP_GPG" ]]; then
        rm -f "$TMP_GPG"
        log_warn "  gpg dearmor failed (rc=$GPG_RC) — trying next source"
        continue
    fi

    # Validate the output is a binary GPG keyring, NOT armored ASCII.
    # If `file` reports "ASCII text" or "PGP public key block" it means
    # dearmor failed silently — apt will ignore it with "unsupported filetype".
    FILETYPE=$(file -b "$TMP_GPG" 2>/dev/null || echo "unknown")
    if echo "$FILETYPE" | grep -qiE "ASCII text|PGP public key block|HTML|XML"; then
        log_warn "  Output is not binary GPG keyring (got: $FILETYPE) — skipping"
        rm -f "$TMP_GPG"
        continue
    fi

    # Success — move into place
    mv "$TMP_GPG" "$DS_GPG"
    chmod 644 "$DS_GPG"
    KEY_OK=true
    log_ok "  Key written: $DS_GPG ($FILETYPE)"
    break
done

if $KEY_OK; then
    # Write sources list with signed-by= (Ubuntu 24.04 requirement)
    # arch= prevents "skipping non-matching" warnings on multi-arch systems
    echo "deb [arch=$(dpkg --print-architecture) signed-by=${DS_GPG}] \
https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu ${CODENAME} main" \
        > "$DS_LIST"

    log_info "  Running apt-get update..."
    APT_OUT=$(apt-get -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=5 -o Acquire::https::Timeout=5 -o Acquire::Retries=1 update 2>&1)
    APT_RC=$?

    # Always show what apt did with the deadsnakes repo specifically.
    # "Hit:" = index downloaded OK. "Ign:" = silently skipped (network blip,
    # clock skew, or bad key). "Err:" = hard error.
    # This is the most useful diagnostic line in the entire install.
    DS_LINE=$(echo "$APT_OUT" | grep -i "deadsnakes" | head -5 || true)
    if [[ -n "$DS_LINE" ]]; then
        log_info "  apt deadsnakes status: $DS_LINE"
    else
        log_warn "  deadsnakes repo not mentioned in apt output (may be issue)"
    fi

    if echo "$APT_OUT" | grep -qiE "deadsnakes.*(NO_PUBKEY|not signed|BADSIG)"; then
        log_warn "  apt rejected the deadsnakes key — output:"
        echo "$APT_OUT" | grep -iE "deadsnakes|NO_PUBKEY|BADSIG|sign" | head -10
        KEY_OK=false
    elif echo "$APT_OUT" | grep -qiE "^Ign.*deadsnakes|^Err.*deadsnakes"; then
        log_warn "  apt IGNORED or ERRORED on deadsnakes repo (index not downloaded)"
        echo "$APT_OUT" | grep -iE "deadsnakes" | head -5
        KEY_OK=false
    elif [[ $APT_RC -ne 0 ]]; then
        log_warn "  apt-get update non-zero exit (may be unrelated):"
        echo "$APT_OUT" | grep -i "^E:\|^W:" | head -5 || true
        # Non-fatal for unrelated repos — try install anyway
    fi
fi

if $KEY_OK; then
    # Verify the package index was actually populated BEFORE calling install.
    # apt-get update exits 0 even when deadsnakes was silently skipped (Ign:).
    # `apt-cache policy` is the only reliable way to confirm a Candidate exists.
    # Without this check, apt-get install gives the misleading
    # "E: Unable to locate package python3.11" error even when the key is fine.
    log_info "  Checking apt-cache for python3.11 candidate..."
    CANDIDATE=$(apt-cache policy python3.11 2>/dev/null \
        | grep "Candidate:" | awk '{print $2}')

    if [[ -z "$CANDIDATE" || "$CANDIDATE" == "(none)" ]]; then
        log_warn "  No installable candidate found (index not populated from PPA)"
        log_warn "  apt-cache output:"
        apt-cache policy python3.11 2>&1 | head -10 || true
        KEY_OK=false   # fall through to add-apt-repository sub-fallback
    else
        log_ok "  Candidate found: python3.11 = $CANDIDATE"
        log_info "  Installing python3.11 packages..."
        if apt-get -o Acquire::ForceIPv4=true install -y -q \
                python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1; then
            PY311=$(command -v python3.11 2>/dev/null || true)
            [[ -n "$PY311" ]] && log_ok "  python3.11 installed via deadsnakes PPA"
        else
            log_warn "  apt-get install failed — showing output:"
            apt-get -o Acquire::ForceIPv4=true install -y python3.11 python3.11-venv python3.11-dev \
                2>&1 | head -25 || true
        fi
    fi
fi

fi  # end [[ -z PY311 ]] block for Method B

# ── Method B2: add-apt-repository sub-fallback ────────────────────
# Only reached if: all 3 key URLs failed, OR apt rejected the key.
if [[ -z "$PY311" ]]; then
    log_warn "Method B direct fetch failed — trying add-apt-repository..."

    # Clean slate before add-apt-repository writes its own files
    rm -f "$DS_GPG" "$DS_LIST" \
          /etc/apt/trusted.gpg.d/deadsnakes*.gpg \
          /etc/apt/sources.list.d/deadsnakes*.list 2>/dev/null || true

    DEBIAN_FRONTEND=noninteractive \
        add-apt-repository -y ppa:deadsnakes/ppa > /dev/null 2>&1 || true

    # add-apt-repository on Ubuntu 24.04 still puts the key in the
    # deprecated trusted.gpg.d — migrate to /etc/apt/keyrings/ and
    # patch signed-by= into the sources line (24.04 requirement).
    LEGACY=$(find /etc/apt/trusted.gpg.d/ -maxdepth 1 \
        -name "deadsnakes*.gpg" -print 2>/dev/null | head -1 || true)
    if [[ -n "$LEGACY" ]]; then
        cp "$LEGACY" "$DS_GPG"
        chmod 644 "$DS_GPG"
        rm -f "$LEGACY"
        AAR_SRC=$(find /etc/apt/sources.list.d/ -maxdepth 1 \
            -name "deadsnakes*.list" -print 2>/dev/null | head -1 || true)
        if [[ -n "$AAR_SRC" ]] && ! grep -q "signed-by" "$AAR_SRC" 2>/dev/null; then
            ARCH=$(dpkg --print-architecture)
            sed -i \
                "s|^deb |deb [arch=${ARCH} signed-by=${DS_GPG}] |" \
                "$AAR_SRC" 2>/dev/null || true
        fi
    fi

    apt-get -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=5 -o Acquire::https::Timeout=5 -o Acquire::Retries=1 update -y -q > /dev/null 2>&1

    # Same candidate check for the add-apt-repository fallback path
    AAR_CANDIDATE=$(apt-cache policy python3.11 2>/dev/null \
        | grep "Candidate:" | awk '{print $2}')
    if [[ -n "$AAR_CANDIDATE" && "$AAR_CANDIDATE" != "(none)" ]]; then
        log_ok "  Candidate found via add-apt-repository: $AAR_CANDIDATE"
        apt-get -o Acquire::ForceIPv4=true install -y -q \
            python3.11 python3.11-venv python3.11-dev > /dev/null 2>&1 || true
    else
        log_warn "  add-apt-repository fallback: still no candidate — will compile from source"
    fi
    PY311=$(command -v python3.11 2>/dev/null || true)
fi

# ── Method C: compile from source (last resort, ~8–10 min) ────────
if [[ -z "$PY311" ]]; then
    log_warn "Both PPA methods failed. Compiling Python 3.11.9 from source..."
    log_warn "This will take approximately 8–10 minutes. Please wait..."

    # Build deps deferred here so the happy path stays fast
    apt-get -o Acquire::ForceIPv4=true install -y -q \
        build-essential libssl-dev libffi-dev \
        zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
        liblzma-dev > /dev/null 2>&1 || true

    PY_SRC=$(mktemp -d)
    cd "$PY_SRC" || fatal "Cannot create temp dir for Python source build."

    log_info "Downloading Python 3.11.9..."
    wget -q --tries=3 --timeout=60 \
        "https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz" \
        || fatal "Source download failed. Check network connectivity."

    tar -xzf Python-3.11.9.tgz
    cd Python-3.11.9 || fatal "Cannot enter Python source directory."

    log_info "Configuring (--with-lto, skip PGO to halve compile time)..."
    ./configure --with-lto --prefix=/usr/local > /dev/null 2>&1 \
        || fatal "Python ./configure failed."

    log_info "Compiling with $(nproc) cores..."
    make -j"$(nproc)" > /dev/null 2>&1 \
        || fatal "Python make failed."

    log_info "Installing (altinstall — does not replace system python3)..."
    make altinstall > /dev/null 2>&1 \
        || fatal "Python make altinstall failed."

    cd /
    rm -rf "$PY_SRC"
    PY311=$(command -v python3.11 2>/dev/null || true)
    [[ -n "$PY311" ]] && python3.11 -m ensurepip --upgrade > /dev/null 2>&1 || true
fi

fi  # end outer [[ -n PY311 ]] guard

[[ -z "$PY311" ]] && fatal \
    "All Python 3.11 installation methods failed.\nInstall manually then re-run."

# Ensure venv module is present (deadsnakes splits it as a sub-package)
if ! python3.11 -m venv --help > /dev/null 2>&1; then
    log_info "Installing python3.11-venv..."
    apt-get -o Acquire::ForceIPv4=true install -y -q python3.11-venv > /dev/null 2>&1 \
        || apt-get -o Acquire::ForceIPv4=true install -y -q python3-venv > /dev/null 2>&1 || true
fi

log_ok "Python 3.11 ready: $(python3.11 --version 2>&1)"

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

# Safe flatten using mapfile+find — immune to filenames with spaces or
# glob characters (parsing `ls` output is unsafe in bash)
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
#
#  uv is installed to /usr/local/bin via UV_INSTALL_DIR so it is
#  on PATH regardless of whether this script runs as root (sudo bash,
#  HOME=/root where ~/.local/bin may not be on PATH) or a normal
#  sudoer — confirmed fix for astral-sh/uv issue #13309.
#
#  VIRTUAL_ENV="$(pwd)/venv" tells uv to target our 'venv' directory
#  instead of its default '.venv' lookup path.
# ══════════════════════════════════════════════════════════════════
log_section "5/6" "Creating Python 3.11 virtual environment"

UV_BIN=$(command -v uv 2>/dev/null || true)
if [[ -z "$UV_BIN" ]]; then
    log_info "Installing uv to /usr/local/bin..."
    curl -fsSL --max-time 30 https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin sh > /dev/null 2>&1 || true
    UV_BIN=$(command -v uv 2>/dev/null || true)
    [[ -n "$UV_BIN" ]] && log_ok "uv installed: $UV_BIN" \
                       || log_warn "uv install failed — falling back to pip"
fi

log_info "Creating venv..."
if [[ -n "$UV_BIN" ]]; then
    "$UV_BIN" venv --python python3.11 venv > /dev/null 2>&1 \
        || python3.11 -m venv venv \
        || fatal "venv creation failed.\nTry: apt-get install -y python3.11-venv"
else
    python3.11 -m venv venv \
        || fatal "python3.11 -m venv failed.\nTry: apt-get install -y python3.11-venv"
fi
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
if [[ -n "$UV_BIN" ]]; then
    if ! VIRTUAL_ENV="$(pwd)/venv" \
            "$UV_BIN" pip install "${DEPS[@]}" > /dev/null 2>&1; then
        log_warn "uv quiet install failed — retrying with output:"
        VIRTUAL_ENV="$(pwd)/venv" \
            "$UV_BIN" pip install "${DEPS[@]}" \
            || fatal "Dependency installation failed. See output above."
    fi
else
    ./venv/bin/python -m pip install -q --upgrade pip setuptools wheel \
        || fatal "pip upgrade failed."
    if ! ./venv/bin/python -m pip install -q --prefer-binary \
            "${DEPS[@]}" > /dev/null 2>&1; then
        log_warn "pip quiet install failed — retrying with output:"
        ./venv/bin/python -m pip install --prefer-binary "${DEPS[@]}" \
            || fatal "Dependency installation failed. See output above."
    fi
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

# sleep 4: enough time for systemd to register an immediate crash+restart
# cycle (RestartSec=5 means a crashed service shows as 'activating'
# briefly — 4 s catches the first failure window reliably)
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
