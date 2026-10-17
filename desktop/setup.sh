#!/usr/bin/env bash
# DG Bank demo desktop — runs on the instance as root (deploy-desktop.sh sends it with SSM Run Command).
# Safe to run again: it reinstalls nothing that is already there and rewrites the agent config.
#
# Inputs (environment): GW_URL      AI Gateway LLM endpoint, e.g. http://<internal-nlb>:8080
#                       GW_MCP_URL  AI Gateway MCP Connect URL for dgbank-mcp (optional)
#                       REGION      AWS region of the SSM parameter /dgbank/gateway-key-laptop
#                       V1_EVENTS   Vision One gateway Events URL (browser bookmark)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

DEMO_USER=demo
DEMO_HOME=/home/$DEMO_USER
MODEL=dgbank-chat
OPENWEBUI_IMAGE=${OPENWEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}

: "${GW_URL:?GW_URL is required}"
: "${REGION:?REGION is required}"

log() { echo "[desktop] $*"; }

# ── Packages: XFCE, TigerVNC, noVNC, Docker, Chrome ──────────────────────────
if ! command -v vncserver >/dev/null; then
  log "Installing the desktop (5–10 minutes)..."
  apt-get update -q
  apt-get install -y -q xfce4 xfce4-terminal dbus-x11 tigervnc-standalone-server novnc websockify \
    docker.io git curl jq unzip fonts-dejavu python3-venv
fi
if ! command -v google-chrome >/dev/null; then
  log "Installing Chrome..."
  curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y -q /tmp/chrome.deb
fi
if ! command -v aws >/dev/null; then
  curl -fsSL -o /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
  unzip -q -o /tmp/awscli.zip -d /tmp && /tmp/aws/install
fi
id "$DEMO_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEMO_USER"
systemctl enable --now docker

# ── engineer-laptop virtual key from SSM ─────────────────────────────────────
KEY=$(aws ssm get-parameter --region "$REGION" --name /dgbank/gateway-key-laptop \
  --with-decryption --query Parameter.Value --output text)

# ── VNC on localhost only; noVNC on :6080 for the DG Bank app (the security group admits only the app) ──
install -d -o "$DEMO_USER" -g "$DEMO_USER" "$DEMO_HOME/.vnc"
cat > "$DEMO_HOME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startxfce4
EOF
chmod 755 "$DEMO_HOME/.vnc/xstartup"
chown "$DEMO_USER:$DEMO_USER" "$DEMO_HOME/.vnc/xstartup"

# No VNC password: VNC listens on localhost only. noVNC (6080) is reachable only from the DG Bank
# app's security group, and the app asks for the access code before it relays anything.
cat > /etc/systemd/system/demo-vnc.service <<EOF
[Unit]
Description=Demo desktop (TigerVNC :1)
After=network.target

[Service]
User=$DEMO_USER
WorkingDirectory=$DEMO_HOME
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStart=/usr/bin/vncserver :1 -fg -localhost yes -geometry 1600x900 -depth 24 -SecurityTypes None --I-KNOW-THIS-IS-INSECURE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/demo-novnc.service <<'EOF'
[Unit]
Description=noVNC for the demo desktop
After=demo-vnc.service
Requires=demo-vnc.service

[Service]
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 0.0.0.0:6080 127.0.0.1:5901
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# ── Open WebUI: a ChatGPT-style app whose only model provider is the gateway ──
log "Starting Open WebUI..."
docker rm -f open-webui >/dev/null 2>&1 || true
docker run -d --name open-webui --restart always -p 127.0.0.1:3000:8080 \
  -v open-webui:/app/backend/data \
  -e WEBUI_AUTH=False \
  -e ENABLE_OLLAMA_API=False \
  -e OPENAI_API_BASE_URL="$GW_URL/v1" \
  -e OPENAI_API_KEY="$KEY" \
  -e DEFAULT_MODELS="$MODEL" \
  "$OPENWEBUI_IMAGE" >/dev/null

# ── Hermes Agent, pointed at the gateway (model and MCP tools) ───────────────
if [[ ! -x "$DEMO_HOME/hermes-agent/.venv/bin/hermes" ]]; then
  log "Installing Hermes Agent..."
  # Run Command starts in a directory the demo user can't write to
  sudo -u "$DEMO_USER" -H bash -lc '
    set -e
    cd "$HOME"
    command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    [ -d hermes-agent ] || git clone --depth 1 https://github.com/NousResearch/hermes-agent.git
    cd hermes-agent && uv venv && uv pip install -e ".[mcp]"'
fi
ln -sf "$DEMO_HOME/hermes-agent/.venv/bin/hermes" /usr/local/bin/hermes

install -d -o "$DEMO_USER" -g "$DEMO_USER" "$DEMO_HOME/.hermes"
{
  echo "# Written by deploy-desktop.sh — every call goes through the AI Gateway as engineer-laptop"
  echo "model:"
  echo "  provider: custom"
  echo "  base_url: $GW_URL/v1"
  echo "  api_key: $KEY"
  echo "  default: $MODEL"
  if [[ -n "${GW_MCP_URL:-}" ]]; then
    echo "mcp_servers:"
    echo "  dgbank:"
    echo "    url: $GW_MCP_URL"
    echo "    headers:"
    echo "      Authorization: \"Bearer $KEY\""
  fi
} > "$DEMO_HOME/.hermes/config.yaml"
chmod 600 "$DEMO_HOME/.hermes/config.yaml"
chown "$DEMO_USER:$DEMO_USER" "$DEMO_HOME/.hermes/config.yaml"

# ── Desktop shortcuts ────────────────────────────────────────────────────────
DESK="$DEMO_HOME/Desktop"
install -d -o "$DEMO_USER" -g "$DEMO_USER" "$DESK"
shortcut() {  # file name, label, command, icon
  cat > "$DESK/$1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Exec=$3
Icon=$4
Terminal=false
EOF
  chmod 755 "$DESK/$1.desktop"; chown "$DEMO_USER:$DEMO_USER" "$DESK/$1.desktop"
}
# --password-store=basic: no "choose a password for the keyring" prompt on the shared desktop
CHROME="google-chrome --no-first-run --no-default-browser-check --password-store=basic"
shortcut hermes      "Hermes Agent"     "xfce4-terminal --title=Hermes --geometry=120x36 -x hermes" utilities-terminal
shortcut open-webui  "Open WebUI" "$CHROME http://localhost:3000" google-chrome
shortcut vision-one  "Vision One Events" "$CHROME ${V1_EVENTS:-https://portal.sg.xdr.trendmicro.com/}" google-chrome
# XFCE asks before running a launcher it hasn't seen; mark them trusted
for f in "$DESK"/*.desktop; do
  sudo -u "$DEMO_USER" dbus-launch gio set "$f" metadata::trusted true 2>/dev/null || true
done

# ── Stop the instance after 60 idle minutes (no one connected to noVNC) ──────
cat > /usr/local/bin/demo-idle-stop <<'IDLE'
#!/bin/bash
# Runs every 5 minutes. A connection to :6080 resets the clock; the clock also starts at boot.
STAMP=/run/demo-last-active
IDLE_MINUTES=60
[[ -f $STAMP ]] || touch $STAMP
if [[ -n "$(ss -Htn state established '( sport = :6080 )')" ]]; then touch $STAMP; exit 0; fi
if [[ $(( ($(date +%s) - $(stat -c %Y $STAMP)) / 60 )) -ge $IDLE_MINUTES ]]; then
  logger "demo desktop idle for $IDLE_MINUTES minutes, stopping"
  shutdown -h now        # the instance's shutdown behaviour is stop, so it can be started again
fi
IDLE
chmod 755 /usr/local/bin/demo-idle-stop
cat > /etc/systemd/system/demo-idle-stop.service <<'IDLE'
[Unit]
Description=Stop the demo desktop when idle

[Service]
Type=oneshot
ExecStart=/usr/local/bin/demo-idle-stop
IDLE
cat > /etc/systemd/system/demo-idle-stop.timer <<'IDLE'
[Unit]
Description=Check every 5 minutes whether the demo desktop is idle

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
IDLE

systemctl daemon-reload
systemctl enable demo-vnc.service demo-novnc.service
systemctl restart demo-vnc.service demo-novnc.service
systemctl enable --now demo-idle-stop.timer

# ── Self-check: the gateway answers with the engineer-laptop key ─────────────
log "Checking the gateway as engineer-laptop..."
curl -sS -m 30 "$GW_URL/v1/chat/completions" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -H 'Accept-Encoding: identity' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK.\"}]}" \
  | jq -r '.choices[0].message.content // .error.message // .' | head -c 300; echo
log "Done."
