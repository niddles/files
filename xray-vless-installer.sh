#!/bin/bash
# ============================================================================
#  VLESS + XRAY Reality VPN Server Installer
#  For Ubuntu 24.04 LTS
#
#  This script automates the full installation and configuration of an
#  XRAY-core server with VLESS protocol and XTLS-Reality transport.
#
#  Website: https://extravm.com
# ============================================================================

set -e

# --- Colors & Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
OUTPUT_FILE="/root/xray-client-config.txt"

# --- Helper Functions ---

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║        VLESS + XRAY Reality VPN Server Installer         ║${NC}"
    echo -e "${CYAN}${BOLD}║                    Ubuntu 24.04 LTS                      ║${NC}"
    echo -e "${CYAN}${BOLD}║                   https://extravm.com                    ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[  OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[FAIL]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root."
        echo "  Please run: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        warn "This script is designed for Ubuntu. It may not work correctly on your OS."
        read -rp "Continue anyway? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
}

check_port_443() {
    if ss -tlnp | grep -q ':443 '; then
        warn "Port 443 is already in use by another service:"
        ss -tlnp | grep ':443 '
        echo ""
        read -rp "Stop the conflicting service and continue? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # Try to identify and stop common services on 443
            systemctl stop nginx 2>/dev/null && info "Stopped nginx" || true
            systemctl stop apache2 2>/dev/null && info "Stopped apache2" || true
            systemctl stop httpd 2>/dev/null && info "Stopped httpd" || true
            sleep 1
            if ss -tlnp | grep -q ':443 '; then
                error "Port 443 is still in use. Please free it manually and re-run the script."
                exit 1
            fi
        else
            exit 1
        fi
    fi
}

get_server_ip() {
    SERVER_IP=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -4 -s --max-time 5 https://icanhazip.com 2>/dev/null \
        || hostname -I | awk '{print $1}')

    if [[ -z "$SERVER_IP" ]]; then
        error "Could not detect server IP address."
        read -rp "Enter your server's public IP manually: " SERVER_IP
        if [[ -z "$SERVER_IP" ]]; then
            error "No IP address provided. Exiting."
            exit 1
        fi
    fi
}

# --- SNI Domain Selection ---

select_sni_domain() {
    echo ""
    echo -e "${BOLD}Select a destination (SNI) domain for Reality:${NC}"
    echo ""
    echo -e "  The domain you choose will be impersonated by your server's TLS"
    echo -e "  fingerprint. Pick a major site with TLSv1.3 & HTTP/2 support."
    echo ""
    echo -e "  ${BOLD} #  Domain                  Notes${NC}"
    echo -e "  ─────────────────────────────────────────────────────────"
    echo -e "  ${GREEN}1)${NC}  www.microsoft.com       Recommended — widely used, stable"
    echo -e "  ${GREEN}2)${NC}  www.apple.com           Good global coverage"
    echo -e "  ${GREEN}3)${NC}  www.amazon.com          High traffic, good for blending in"
    echo -e "  ${GREEN}4)${NC}  dl.google.com           Google download servers"
    echo -e "  ${GREEN}5)${NC}  www.samsung.com         Reliable, supports TLSv1.3"
    echo -e "  ${GREEN}6)${NC}  www.cloudflare.com      Fast, excellent TLS support"
    echo -e "  ${GREEN}7)${NC}  www.mozilla.org         Firefox — good global CDN"
    echo -e "  ${GREEN}8)${NC}  Custom domain            Enter your own"
    echo ""

    while true; do
        read -rp "  Enter your choice [1-8] (default: 1): " sni_choice
        sni_choice=${sni_choice:-1}

        case "$sni_choice" in
            1) SNI_DOMAIN="www.microsoft.com" ;;
            2) SNI_DOMAIN="www.apple.com" ;;
            3) SNI_DOMAIN="www.amazon.com" ;;
            4) SNI_DOMAIN="dl.google.com" ;;
            5) SNI_DOMAIN="www.samsung.com" ;;
            6) SNI_DOMAIN="www.cloudflare.com" ;;
            7) SNI_DOMAIN="www.mozilla.org" ;;
            8)
                read -rp "  Enter custom domain (e.g. www.example.com): " SNI_DOMAIN
                if [[ -z "$SNI_DOMAIN" ]]; then
                    warn "No domain entered. Please try again."
                    continue
                fi
                ;;
            *)
                warn "Invalid choice. Please enter a number between 1 and 8."
                continue
                ;;
        esac
        break
    done

    # Validate the chosen domain supports TLSv1.3 using openssl
    info "Validating ${SNI_DOMAIN} supports TLSv1.3..."
    TLS_VER=$(echo | openssl s_client -connect "${SNI_DOMAIN}:443" -servername "${SNI_DOMAIN}" -tls1_3 2>/dev/null | grep -o "TLSv1\.3" | head -1 || true)
    H2_SUPPORT=$(echo | openssl s_client -connect "${SNI_DOMAIN}:443" -servername "${SNI_DOMAIN}" -tls1_3 -alpn h2 2>/dev/null | grep -o "h2" | head -1 || true)

    if [[ "$TLS_VER" == "TLSv1.3" ]]; then
        if [[ "$H2_SUPPORT" == "h2" ]]; then
            success "${SNI_DOMAIN} supports TLSv1.3 + HTTP/2 ✓"
        else
            success "${SNI_DOMAIN} supports TLSv1.3 ✓"
            warn "HTTP/2 (h2) could not be confirmed, but this is usually fine."
        fi
    else
        warn "Could not confirm TLSv1.3 support for ${SNI_DOMAIN}."
        warn "This may be due to network restrictions. The domain might still work."
        read -rp "  Continue with this domain anyway? (Y/n): " confirm
        [[ "$confirm" =~ ^[Nn]$ ]] && select_sni_domain
    fi
}

# --- Installation Steps ---

install_dependencies() {
    info "Updating system packages..."
    apt update -qq -y > /dev/null 2>&1
    apt upgrade -qq -y > /dev/null 2>&1
    success "System packages updated."

    info "Installing dependencies (curl, openssl, jq)..."
    apt install -qq -y curl openssl jq unzip > /dev/null 2>&1
    success "Dependencies installed."
}

install_xray() {
    if command -v xray &> /dev/null; then
        CURRENT_VER=$(xray version | head -1 | awk '{print $2}')
        warn "XRAY-core is already installed (version ${CURRENT_VER})."
        read -rp "  Reinstall / upgrade? (Y/n): " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            success "Keeping existing XRAY installation."
            return
        fi
    fi

    info "Installing XRAY-core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

    if command -v xray &> /dev/null; then
        XRAY_VER=$(xray version | head -1 | awk '{print $2}')
        success "XRAY-core ${XRAY_VER} installed successfully."
    else
        error "XRAY-core installation failed. Please check your network connection."
        exit 1
    fi
}

generate_credentials() {
    info "Generating credentials..."

    CLIENT_UUID=$(xray uuid)

    # Generate the key pair
    KEY_OUTPUT=$(xray x25519 2>&1)

    # Extract private key (first line, last field — works across versions)
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | head -1 | awk '{print $NF}')

    if [[ -z "$PRIVATE_KEY" ]]; then
        error "Failed to extract private key. Raw output from 'xray x25519':"
        echo "$KEY_OUTPUT"
        exit 1
    fi

    # Derive public key from private key (reliable across all XRAY versions)
    # In XRAY 26.x output: line 1 = PrivateKey, line 2 = Password (public key), line 3 = Hash32
    DERIVE_OUTPUT=$(xray x25519 -i "$PRIVATE_KEY" 2>&1)
    PUBLIC_KEY=$(echo "$DERIVE_OUTPUT" | grep -iE "^public|^password" | head -1 | awk '{print $NF}')

    # Fallback: if grep didn't match, grab the second line's last field
    if [[ -z "$PUBLIC_KEY" ]]; then
        PUBLIC_KEY=$(echo "$DERIVE_OUTPUT" | sed -n '2p' | awk '{print $NF}')
    fi

    if [[ -z "$PUBLIC_KEY" ]]; then
        error "Failed to derive public key. Raw output from 'xray x25519 -i':"
        xray x25519 -i "$PRIVATE_KEY"
        exit 1
    fi

    SHORT_ID=$(openssl rand -hex 8)

    success "UUID:        ${CLIENT_UUID}"
    success "Private Key: ${PRIVATE_KEY}"
    success "Public Key:  ${PUBLIC_KEY}"
    success "Short ID:    ${SHORT_ID}"
}

enable_bbr() {
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$CURRENT_CC" == "bbr" ]]; then
        success "BBR congestion control is already enabled."
        return
    fi

    info "Enabling BBR congestion control for better performance..."
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    success "BBR enabled."
}

write_xray_config() {
    info "Writing XRAY configuration..."

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${CLIENT_UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${SNI_DOMAIN}:443",
                    "xver": 0,
                    "serverNames": [
                        "${SNI_DOMAIN}"
                    ],
                    "privateKey": "${PRIVATE_KEY}",
                    "shortIds": [
                        "${SHORT_ID}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": [
                    "geoip:private"
                ],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:category-ads-all"
                ],
                "outboundTag": "block"
            }
        ]
    }
}
EOF

    # Validate config
    if xray run -test -c "$CONFIG_FILE" > /dev/null 2>&1; then
        success "XRAY configuration is valid."
    else
        error "XRAY configuration validation failed!"
        xray run -test -c "$CONFIG_FILE"
        exit 1
    fi
}

configure_firewall() {
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        info "Configuring UFW firewall..."
        ufw allow 443/tcp > /dev/null 2>&1
        success "UFW: Port 443/tcp allowed."
    else
        info "UFW not active. Checking iptables..."
        if ! iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -p tcp --dport 443 -j ACCEPT
            success "iptables: Port 443/tcp allowed."
        else
            success "Port 443/tcp is already allowed."
        fi
    fi
}

start_xray() {
    info "Starting XRAY service..."
    systemctl daemon-reload
    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray

    sleep 2

    if systemctl is-active --quiet xray; then
        success "XRAY service is running!"
    else
        error "XRAY failed to start. Checking logs..."
        journalctl -u xray --no-pager -n 20
        exit 1
    fi
}

# --- Generate VLESS Share Link ---

generate_vless_link() {
    # Standard VLESS share URI format
    VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#XRAY-Reality-${SERVER_IP}"
}

# --- Output Results ---

save_client_config() {
    cat > "$OUTPUT_FILE" <<EOF
╔══════════════════════════════════════════════════════════════════╗
║           XRAY VLESS Reality — Client Connection Info           ║
║                     Generated: $(date '+%Y-%m-%d %H:%M:%S')                ║
╚══════════════════════════════════════════════════════════════════╝

 SERVER DETAILS
──────────────────────────────────────────────────────────────────
  Server IP:      ${SERVER_IP}
  Port:           443
  Protocol:       VLESS
  Encryption:     none
  Flow:           xtls-rprx-vision
  Transport:      TCP
  Security:       Reality

 REALITY SETTINGS
──────────────────────────────────────────────────────────────────
  SNI Domain:     ${SNI_DOMAIN}
  Fingerprint:    chrome
  Public Key:     ${PUBLIC_KEY}
  Short ID:       ${SHORT_ID}

 CLIENT AUTHENTICATION
──────────────────────────────────────────────────────────────────
  UUID:           ${CLIENT_UUID}

 SHARE LINK (paste into your client app)
──────────────────────────────────────────────────────────────────
${VLESS_LINK}

 RECOMMENDED CLIENT APPS
──────────────────────────────────────────────────────────────────
  Windows:    v2rayN       https://github.com/2dust/v2rayN
  macOS:      V2BOX        https://apps.apple.com/app/id6446814690
              FoXray       https://apps.apple.com/app/id6448898396
  iOS:        V2BOX        https://apps.apple.com/app/id6446814690
              Streisand    https://apps.apple.com/app/id6450534064
  Android:    v2rayNG      https://github.com/2dust/v2rayNG
  Linux:      Nekoray      https://github.com/MatsuriDayo/nekoray

 SERVER KEYS (KEEP PRIVATE — DO NOT SHARE)
──────────────────────────────────────────────────────────────────
  Private Key:    ${PRIVATE_KEY}
  Config File:    ${CONFIG_FILE}

══════════════════════════════════════════════════════════════════
  Powered by ExtraVM — https://extravm.com
══════════════════════════════════════════════════════════════════
EOF

    chmod 600 "$OUTPUT_FILE"
    success "Client configuration saved to ${OUTPUT_FILE}"
}

print_results() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║          ✅  Installation Complete — Connection Info            ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Server IP:${NC}      ${GREEN}${SERVER_IP}${NC}"
    echo -e "  ${BOLD}Port:${NC}           ${GREEN}443${NC}"
    echo -e "  ${BOLD}Protocol:${NC}       ${GREEN}VLESS${NC}"
    echo -e "  ${BOLD}Flow:${NC}           ${GREEN}xtls-rprx-vision${NC}"
    echo -e "  ${BOLD}Transport:${NC}      ${GREEN}TCP${NC}"
    echo -e "  ${BOLD}Security:${NC}       ${GREEN}Reality${NC}"
    echo ""
    echo -e "  ${BOLD}SNI Domain:${NC}     ${GREEN}${SNI_DOMAIN}${NC}"
    echo -e "  ${BOLD}Fingerprint:${NC}    ${GREEN}chrome${NC}"
    echo -e "  ${BOLD}Public Key:${NC}     ${GREEN}${PUBLIC_KEY}${NC}"
    echo -e "  ${BOLD}Short ID:${NC}       ${GREEN}${SHORT_ID}${NC}"
    echo ""
    echo -e "  ${BOLD}UUID:${NC}           ${GREEN}${CLIENT_UUID}${NC}"
    echo ""
    echo -e "  ${BOLD}${YELLOW}VLESS Share Link (paste into your client app):${NC}"
    echo ""
    echo -e "  ${GREEN}${VLESS_LINK}${NC}"
    echo ""
    echo -e "  ──────────────────────────────────────────────────────────"
    echo -e "  ${BOLD}Config saved to:${NC}  ${YELLOW}${OUTPUT_FILE}${NC}"
    echo -e "  ${BOLD}Server config:${NC}    ${YELLOW}${CONFIG_FILE}${NC}"
    echo -e "  ──────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${BOLD}Manage the service:${NC}"
    echo -e "    Start:    ${CYAN}systemctl start xray${NC}"
    echo -e "    Stop:     ${CYAN}systemctl stop xray${NC}"
    echo -e "    Restart:  ${CYAN}systemctl restart xray${NC}"
    echo -e "    Status:   ${CYAN}systemctl status xray${NC}"
    echo -e "    Logs:     ${CYAN}journalctl -u xray -f${NC}"
    echo ""
    echo -e "  ${CYAN}Powered by ExtraVM — https://extravm.com${NC}"
    echo ""
}

# ============================================================================
#  Main Execution
# ============================================================================

main() {
    print_banner
    check_root
    check_os
    check_port_443

    info "Detecting server IP address..."
    get_server_ip
    success "Server IP: ${SERVER_IP}"

    select_sni_domain

    echo ""
    echo -e "${BOLD}  Ready to install with the following settings:${NC}"
    echo -e "    Server IP:   ${GREEN}${SERVER_IP}${NC}"
    echo -e "    SNI Domain:  ${GREEN}${SNI_DOMAIN}${NC}"
    echo ""
    read -rp "  Proceed with installation? (Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

    echo ""
    install_dependencies
    install_xray
    generate_credentials
    enable_bbr
    write_xray_config
    configure_firewall
    start_xray
    generate_vless_link
    save_client_config
    print_results
}

main "$@"
