#!/data/data/com.termux/files/usr/bin/bash
#
# install_paper_server.sh
#
# Sets up a PaperMC Minecraft server on a fresh Termux install (Android).
# Assumes packages/Java are NOT installed yet. Installs packages, Java,
# lets you pick which Minecraft version to run, how much RAM to give it,
# and common server.properties options - then downloads the matching
# Paper build and creates start/stop scripts.
#
# Usage:
#   bash install_paper_server.sh
#
# After it finishes:
#   cd ~/paperserver
#   ./start.sh
#

set -euo pipefail

# ------------------------------------------------------------------
# Config (edit these if you want)
# ------------------------------------------------------------------
SERVER_DIR="$HOME/paperserver"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
info()  { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn()  { echo -e "\n\033[1;33m[!] $*\033[0m"; }
fail()  { echo -e "\n\033[1;31m[x] $*\033[0m"; exit 1; }

# prompt_default "Question text" "default value" -> echoes chosen value
prompt_default() {
    local question="$1" default="$2" answer
    read -rp "$question [$default]: " answer
    echo "${answer:-$default}"
}

# prompt_yn "Question text" "y|n default" -> echoes "true" or "false"
prompt_yn() {
    local question="$1" default="$2" answer
    while true; do
        read -rp "$question (y/n) [$default]: " answer
        answer="${answer:-$default}"
        case "$answer" in
            y|Y|yes|Yes) echo "true"; return ;;
            n|N|no|No)   echo "false"; return ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# ------------------------------------------------------------------
# 1. Update Termux
# ------------------------------------------------------------------
info "Updating Termux package lists (this can take a minute)..."
pkg update -y
pkg upgrade -y

# ------------------------------------------------------------------
# 2. Install required packages
# ------------------------------------------------------------------
# NOTE ON JAVA VERSION: the newest Paper/Minecraft builds require Java 25+.
# Java is backwards compatible though - a Java 25 JVM will happily run
# server jars that only require Java 17 or 21, so installing openjdk-25
# alone covers every Minecraft version, old or new. No need for multiple
# JDKs side by side.
info "Installing core packages: wget, curl, jq, openjdk-25, screen, tar..."
pkg install -y wget curl jq openjdk-25 screen tar coreutils

info "Java version installed:"
java -version

# ------------------------------------------------------------------
# 3. Create server directory
# ------------------------------------------------------------------
info "Creating server directory at $SERVER_DIR ..."
mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

# ------------------------------------------------------------------
# 4. Let the user pick a Minecraft version, then resolve the matching
#    Paper build via the PaperMC "Fill" v3 API (the old api.papermc.io/v2
#    endpoint was retired - fill.papermc.io/v3 is current, and it requires
#    a descriptive User-Agent header)
# ------------------------------------------------------------------
USER_AGENT="termux-paper-installer/1.0 (https://github.com/anthropics - personal use script)"
PROJECT="paper"
API="https://fill.papermc.io/v3/projects/${PROJECT}"

info "Querying PaperMC Fill API for available versions..."
PROJECT_JSON=$(curl -fsSL -H "User-Agent: $USER_AGENT" "$API")

# .versions is grouped by major version group (e.g. "1.21", "1.20"),
# newest group first, newest version first within each group. Flatten
# that into a single newest-first list for the picker.
mapfile -t ALL_VERSIONS < <(echo "$PROJECT_JSON" | jq -r '.versions | to_entries[] | .value[]')

if [ "${#ALL_VERSIONS[@]}" -eq 0 ]; then
    fail "Could not retrieve any Minecraft versions from the PaperMC API."
fi

LATEST_VERSION="${ALL_VERSIONS[0]}"
LIST_COUNT=25
SHOWN_COUNT=$(( ${#ALL_VERSIONS[@]} < LIST_COUNT ? ${#ALL_VERSIONS[@]} : LIST_COUNT ))

echo ""
echo "Which Minecraft version do you want to run?"
echo "(showing the $SHOWN_COUNT most recent versions - newest first)"
echo ""
for ((i = 0; i < SHOWN_COUNT; i++)); do
    printf "  %2d) %s\n" "$((i + 1))" "${ALL_VERSIONS[$i]}"
done
echo ""
echo "Or type a version number directly (e.g. 1.20.4) if it's not listed above."
read -rp "Enter a number, a version string, or press Enter for latest ($LATEST_VERSION): " CHOICE

if [ -z "$CHOICE" ]; then
    MC_VERSION="$LATEST_VERSION"
elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$SHOWN_COUNT" ]; then
    MC_VERSION="${ALL_VERSIONS[$((CHOICE - 1))]}"
else
    MC_VERSION="$CHOICE"
fi

info "Selected Minecraft version: $MC_VERSION"

info "Fetching latest stable build for Paper $MC_VERSION ..."
BUILDS_JSON=$(curl -fsSL -H "User-Agent: $USER_AGENT" "$API/versions/${MC_VERSION}/builds")

if echo "$BUILDS_JSON" | jq -e '.ok == false' >/dev/null 2>&1; then
    fail "PaperMC API error: $(echo "$BUILDS_JSON" | jq -r '.message // "unknown error"')"
fi

DOWNLOAD_URL=$(echo "$BUILDS_JSON" | jq -r 'map(select(.channel == "STABLE")) | .[0].downloads."server:default".url // empty')
BUILD=$(echo "$BUILDS_JSON" | jq -r 'map(select(.channel == "STABLE")) | .[0].id // empty')

if [ -z "$DOWNLOAD_URL" ]; then
    warn "No STABLE build for $MC_VERSION yet, falling back to the newest build of any channel..."
    DOWNLOAD_URL=$(echo "$BUILDS_JSON" | jq -r '.[0].downloads."server:default".url // empty')
    BUILD=$(echo "$BUILDS_JSON" | jq -r '.[0].id // empty')
fi

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    fail "Could not resolve a Paper build download URL for version $MC_VERSION"
fi

info "Downloading Paper $MC_VERSION build $BUILD ..."
wget -O "$SERVER_DIR/paper.jar" "$DOWNLOAD_URL"

# ------------------------------------------------------------------
# 5. Accept EULA
# ------------------------------------------------------------------
info "Accepting Minecraft EULA..."
cat > "$SERVER_DIR/eula.txt" <<EOF
# Auto-accepted by install_paper_server.sh
eula=true
EOF

# ------------------------------------------------------------------
# 6. Pick how much RAM to give the server
# ------------------------------------------------------------------
TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

if [ "$TOTAL_RAM_MB" -gt 0 ]; then
    # Leave headroom for Android + Termux itself, then suggest ~50% of
    # total as a balanced default, floored at 768MB and capped so we
    # never suggest more than (total - 1GB) for the OS.
    SAFE_CEILING=$(( TOTAL_RAM_MB - 1024 ))
    RECOMMENDED_RAM=$(( TOTAL_RAM_MB / 2 ))
    [ "$RECOMMENDED_RAM" -gt "$SAFE_CEILING" ] && RECOMMENDED_RAM=$SAFE_CEILING
    [ "$RECOMMENDED_RAM" -lt 768 ] && RECOMMENDED_RAM=768
    PERFORMANCE_RAM=$(( TOTAL_RAM_MB * 3 / 4 ))
    [ "$PERFORMANCE_RAM" -gt "$SAFE_CEILING" ] && PERFORMANCE_RAM=$SAFE_CEILING
else
    warn "Couldn't detect total device RAM, using generic defaults."
    RECOMMENDED_RAM=1536
    PERFORMANCE_RAM=2560
fi

echo ""
echo "How much RAM should the server get?"
if [ "$TOTAL_RAM_MB" -gt 0 ]; then
    echo "(detected ~${TOTAL_RAM_MB}MB total device RAM)"
fi
echo ""
echo "  1) Light        - 1024MB (older/low-end phones, small worlds)"
echo "  2) Balanced      - ${RECOMMENDED_RAM}MB (recommended default)"
echo "  3) Performance   - ${PERFORMANCE_RAM}MB (flagship phone, few background apps)"
echo "  4) Custom        - enter an exact amount in MB"
echo ""
read -rp "Choose 1-4 [2]: " RAM_CHOICE
RAM_CHOICE="${RAM_CHOICE:-2}"

case "$RAM_CHOICE" in
    1) RAM_MB=1024 ;;
    2) RAM_MB=$RECOMMENDED_RAM ;;
    3) RAM_MB=$PERFORMANCE_RAM ;;
    4) RAM_MB=$(prompt_default "Enter RAM in MB" "$RECOMMENDED_RAM") ;;
    *) warn "Unrecognized choice, using Balanced."; RAM_MB=$RECOMMENDED_RAM ;;
esac

info "Server will be started with ${RAM_MB}MB of RAM."

# ------------------------------------------------------------------
# 7. Interactive server.properties builder (common options, sensible
#    defaults - just press Enter to accept each default)
# ------------------------------------------------------------------
echo ""
echo "Now let's set up server.properties. Press Enter on any question to"
echo "accept the default shown in brackets."
echo ""

SP_PORT=$(prompt_default "Server port" "25565")
SP_MOTD=$(prompt_default "MOTD (server list message)" "A Paper Server on Termux")
SP_MAX_PLAYERS=$(prompt_default "Max players" "10")
SP_GAMEMODE=$(prompt_default "Gamemode (survival/creative/adventure/spectator)" "survival")
SP_DIFFICULTY=$(prompt_default "Difficulty (peaceful/easy/normal/hard)" "normal")
SP_HARDCORE=$(prompt_yn "Hardcore mode" "n")
SP_PVP=$(prompt_yn "Enable PVP" "y")
SP_ONLINE_MODE=$(prompt_yn "Online mode (verify Minecraft accounts - turn off ONLY for offline/cracked/LAN use)" "y")
SP_WHITELIST=$(prompt_yn "Enable whitelist" "n")
SP_SPAWN_PROTECTION=$(prompt_default "Spawn protection radius (blocks, 0 to disable)" "0")
SP_VIEW_DISTANCE=$(prompt_default "View distance (chunks, lower = better performance)" "8")
SP_SIM_DISTANCE=$(prompt_default "Simulation distance (chunks, lower = better performance)" "6")
SP_ALLOW_NETHER=$(prompt_yn "Allow the Nether" "y")
SP_ALLOW_FLIGHT=$(prompt_yn "Allow flight (needed for some non-cheat mods/elytra edge cases)" "n")
SP_LEVEL_SEED=$(prompt_default "World seed (leave blank for random)" "")
SP_LEVEL_NAME=$(prompt_default "World folder name" "world")

info "Writing server.properties ..."
cat > "$SERVER_DIR/server.properties" <<EOF
server-port=$SP_PORT
motd=$SP_MOTD
max-players=$SP_MAX_PLAYERS
gamemode=$SP_GAMEMODE
difficulty=$SP_DIFFICULTY
hardcore=$SP_HARDCORE
pvp=$SP_PVP
online-mode=$SP_ONLINE_MODE
white-list=$SP_WHITELIST
spawn-protection=$SP_SPAWN_PROTECTION
view-distance=$SP_VIEW_DISTANCE
simulation-distance=$SP_SIM_DISTANCE
allow-nether=$SP_ALLOW_NETHER
allow-flight=$SP_ALLOW_FLIGHT
level-seed=$SP_LEVEL_SEED
level-name=$SP_LEVEL_NAME
enable-command-block=false
EOF

# ------------------------------------------------------------------
# 8. Create start.sh
# ------------------------------------------------------------------
# NOTE ON --nogui: dropped entirely. -Djava.awt.headless=true forces the
# JVM itself into headless mode, so the server never tries to open a GUI
# window regardless of Minecraft/Paper version - no need for the --nogui
# flag (whose recognized name/format varies across old and new builds).
info "Creating start.sh ..."
cat > "$SERVER_DIR/start.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Starts the Paper server. Run with: ./start.sh
cd "\$(dirname "\$0")"

# Keep the phone CPU awake while the server runs (needs termux-api / Termux:API app)
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock

JAVA_OPTS=(
    -Xms${RAM_MB}M -Xmx${RAM_MB}M
    -Djava.awt.headless=true
    -XX:+UseG1GC
    -XX:+ParallelRefProcEnabled
    -XX:MaxGCPauseMillis=200
    -XX:+UnlockExperimentalVMOptions
    -XX:+DisableExplicitGC
    -XX:G1NewSizePercent=30
    -XX:G1MaxNewSizePercent=40
    -XX:G1HeapRegionSize=8M
    -XX:G1ReservePercent=20
)

java "\${JAVA_OPTS[@]}" -jar paper.jar
command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
EOF
chmod +x "$SERVER_DIR/start.sh"

# ------------------------------------------------------------------
# 9. Create a stop helper (for use with screen sessions)
# ------------------------------------------------------------------
cat > "$SERVER_DIR/stop.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Sends "stop" to a running server inside a screen session named "mcserver"
screen -S mcserver -p 0 -X stuff "stop$(printf \\r)"
EOF
chmod +x "$SERVER_DIR/stop.sh"

# ------------------------------------------------------------------
# 10. Create a launcher that runs the server inside screen (so it
#     survives you closing the Termux session)
# ------------------------------------------------------------------
cat > "$SERVER_DIR/run_in_screen.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$(dirname "$0")"
screen -dmS mcserver ./start.sh
echo "Server launched in a detached screen session named 'mcserver'."
echo "Attach to console with:  screen -r mcserver"
echo "Detach again with:       Ctrl+A then D"
EOF
chmod +x "$SERVER_DIR/run_in_screen.sh"

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
info "Install complete!"
echo "Server files are in: $SERVER_DIR"
echo ""
echo "To start the server in the foreground:"
echo "  cd $SERVER_DIR && ./start.sh"
echo ""
echo "To run it in the background (recommended, survives closing Termux):"
echo "  cd $SERVER_DIR && ./run_in_screen.sh"
echo "  screen -r mcserver     # attach to console"
echo "  (Ctrl+A then D to detach without stopping it)"
echo ""
echo "To stop a background server:"
echo "  cd $SERVER_DIR && ./stop.sh"
echo ""
echo "Edit $SERVER_DIR/server.properties any time and restart to change settings."
echo ""
warn "First boot will generate the world and take a while - be patient."
warn "If Termux gets killed by Android in the background, disable battery"
warn "optimization for Termux in Android system settings, and consider"
warn "installing the Termux:API app + 'pkg install termux-api' for wake locks."
echo ""
info "Java note: installed openjdk-25, which runs Paper builds for every"
echo "Minecraft version (older versions only need Java 17-21, and newer"
echo "JVMs run older server jars fine - it's only forward compatibility,"
echo "e.g. an old JVM refusing a new jar, that would ever be a problem)."
