#!/bin/bash
# SwiftMaestro Tracking Relay — VPS deploy script
#
# Run this on your VPS as root or with sudo:
#   curl -sL https://raw.githubusercontent.com/.../deploy.sh | bash
#
# Or copy it to the VPS and run:
#   chmod +x deploy.sh && sudo ./deploy.sh
#
# What it does:
#   1. Installs Node.js 22 (if missing)
#   2. Copies the relay server to /opt/tracking-relay
#   3. Sets up a systemd service
#   4. Generates a signing secret and prints it
#   5. Provides nginx config for track.swiftmaestro.com

set -euo pipefail

RELAY_PORT="${RELAY_PORT:-3087}"
DOMAIN="${DOMAIN:-track.swiftmaestro.com}"
INSTALL_DIR="/opt/tracking-relay"
SIGNING_SECRET=$(openssl rand -hex 32)

echo "╔══════════════════════════════════════════════╗"
echo "║  SwiftMaestro Tracking Relay — Deploy        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# --- 1. Install Node.js if missing ---
if ! command -v node &>/dev/null; then
    echo "▸ Installing Node.js 22..."
    if command -v apt-get &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs
    elif command -v yum &>/dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
        yum install -y nodejs
    else
        echo "⚠  Could not detect package manager. Install Node.js 18+ manually."
        echo "   https://nodejs.org/"
        exit 1
    fi
    echo "   Node $(node -v) installed."
else
    echo "▸ Node.js $(node -v) found."
fi

# --- 2. Copy relay server ---
echo "▸ Installing relay server to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp server.js package.json README.md "$INSTALL_DIR/"

# --- 3. Create systemd service ---
echo "▸ Creating systemd service..."
cat > /etc/systemd/system/tracking-relay.service <<EOF
[Unit]
Description=SwiftMaestro Tracking Relay
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node $INSTALL_DIR/server.js
Restart=always
RestartSec=5
Environment=PORT=$RELAY_PORT
Environment=STORE_PATH=$INSTALL_DIR/relay-store.json
Environment=SIGNING_SECRET=$SIGNING_SECRET
Environment=VERIFY_TOKENS=1

[Install]
WantedBy=multi-user.target
EOF

# --- 4. Start the service ---
echo "▸ Starting relay service..."
systemctl daemon-reload
systemctl enable tracking-relay
systemctl start tracking-relay

sleep 1
if systemctl is-active --quiet tracking-relay; then
    echo "   ✓ Relay running on port $RELAY_PORT"
else
    echo "   ✗ Relay failed to start. Check: journalctl -u tracking-relay"
    exit 1
fi

# --- 5. Print nginx config ---
echo ""
echo "═══════════════════════════════════════════════"
echo "  Nginx config for $DOMAIN"
echo "═══════════════════════════════════════════════"
echo ""
echo "Create /etc/nginx/sites-available/tracking-relay with this content:"
echo ""
cat <<NGINX
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    # SSL — run: certbot --nginx -d $DOMAIN
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$RELAY_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

echo ""
echo "═══════════════════════════════════════════════"
echo "  DNS Setup"
echo "═══════════════════════════════════════════════"
echo ""
echo "Create these DNS records:"
echo "  Type  Name   Value"
echo "  A     track  $(curl -s ifconfig.me 2>/dev/null || echo '<YOUR_VPS_IP>')"
echo ""

echo "═══════════════════════════════════════════════"
echo "  Signing Secret (save this!)"
echo "═══════════════════════════════════════════════"
echo ""
echo "  $SIGNING_SECRET"
echo ""
echo "  This must match the HMAC secret in SwiftMaestro's Keychain."
echo "  To update it later: sudo nano /etc/systemd/system/tracking-relay.service"
echo "  Then: sudo systemctl daemon-reload && sudo systemctl restart tracking-relay"
echo ""

echo "═══════════════════════════════════════════════"
echo "  Next Steps"
echo "═══════════════════════════════════════════════"
echo ""
echo "  1. Add DNS A record: track → $(curl -s ifconfig.me 2>/dev/null || echo '<YOUR_VPS_IP>')"
echo "  2. Install certbot: apt install certbot python3-certbot-nginx"
echo "  3. Get SSL cert: certbot --nginx -d $DOMAIN"
echo "  4. Enable the nginx site:"
echo "       ln -s /etc/nginx/sites-available/tracking-relay /etc/nginx/sites-enabled/"
echo "       nginx -t && systemctl reload nginx"
echo "  5. In SwiftMaestro → Settings → Mail, set Base URL to:"
echo "       https://$DOMAIN"
echo "  6. Test: curl https://$DOMAIN/health"
echo ""
