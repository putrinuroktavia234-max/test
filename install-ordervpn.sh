#!/bin/bash
# ============================================================
#  ORDERVPN WEB INSTALLER
#  Terintegrasi dengan Youzin Crabz Tunel (tunnel.sh)
#  Author : The Professor
#  Version: 1.0.0
# ============================================================

# ─── Ambil warna dari tunnel.sh jika tersedia ───────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
BOLD='\033[1m'; DIM='\033[2m'

ORDERVPN_DIR="/var/www/html/ordervpn"
ORDERVPN_CONF="/etc/nginx/sites-available/ordervpn"
API_BRIDGE="/usr/local/bin/vpn-api"
DOMAIN_FILE="/etc/xray/domain"
LOG="/var/log/ordervpn-install.log"

# ─── Helper: print step ─────────────────────────────────────
_step() { echo -e "  ${CYAN}▸${NC} $1"; }
_ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
_fail() { echo -e "  ${RED}✘${NC} $1"; }
_info() { echo -e "  ${DIM}$1${NC}"; }

print_header() {
    clear
    echo ""
    echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║${NC}  ${BOLD}${WHITE}ORDERVPN WEB INSTALLER${NC}                     ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${DIM}Web Panel Pemesanan VPN (PHP + MySQL)${NC}      ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${DIM}Youzin Crabz Tunel — The Professor${NC}         ${CYAN}║${NC}"
    echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

# ─── Cek root ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}Harus dijalankan sebagai root!${NC}"; exit 1; }

# ─── Deteksi domain tunnel.sh ───────────────────────────────
detect_domain() {
    if [[ -f "$DOMAIN_FILE" ]]; then
        DOMAIN=$(tr -d '\n\r' < "$DOMAIN_FILE" | xargs)
    else
        DOMAIN=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    fi
}

# ─── Install paket yang dibutuhkan ──────────────────────────
install_deps() {
    _step "Mengecek & install dependensi..."
    apt-get update -qq >> "$LOG" 2>&1

    local pkgs=()
    command -v mysql  >/dev/null 2>&1 || pkgs+=(mysql-server)
    command -v php    >/dev/null 2>&1 || pkgs+=(php php-fpm php-mysql php-curl php-mbstring)
    php -m 2>/dev/null | grep -q "pdo_mysql" || pkgs+=(php-mysql)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        _info "Install: ${pkgs[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >> "$LOG" 2>&1
        _ok "Dependensi selesai dipasang"
    else
        _ok "Semua dependensi sudah ada"
    fi
}

# ─── Download / extract OrderVPN ────────────────────────────
deploy_files() {
    _step "Mendeploy file OrderVPN ke ${ORDERVPN_DIR}..."

    if [[ -d "$ORDERVPN_DIR" ]]; then
        _info "Backup direktori lama → ${ORDERVPN_DIR}.bak"
        rm -rf "${ORDERVPN_DIR}.bak"
        mv "$ORDERVPN_DIR" "${ORDERVPN_DIR}.bak"
    fi

    mkdir -p "$ORDERVPN_DIR"

    # Cek apakah ordervpn.zip ada di lokasi standar
    local ZIP_SRC=""
    for loc in /root/ordervpn.zip /tmp/ordervpn.zip "$(dirname "$0")/ordervpn.zip"; do
        [[ -f "$loc" ]] && { ZIP_SRC="$loc"; break; }
    done

    if [[ -n "$ZIP_SRC" ]]; then
        _info "Ekstrak dari $ZIP_SRC"
        unzip -q "$ZIP_SRC" -d /tmp/ordervpn_extract/ >> "$LOG" 2>&1
        # Pindahkan isi folder ordervpn/ dari zip
        if [[ -d /tmp/ordervpn_extract/ordervpn ]]; then
            cp -r /tmp/ordervpn_extract/ordervpn/* "$ORDERVPN_DIR/"
        else
            cp -r /tmp/ordervpn_extract/* "$ORDERVPN_DIR/"
        fi
        rm -rf /tmp/ordervpn_extract
        _ok "File berhasil diekstrak"
    else
        _fail "ordervpn.zip tidak ditemukan! Upload ke /root/ordervpn.zip dulu."
        echo ""
        echo -e "  ${YELLOW}Cara upload:${NC}"
        echo -e "  ${DIM}scp ordervpn.zip root@IP_VPS:/root/ordervpn.zip${NC}"
        echo -e "  ${DIM}Lalu jalankan menu ini lagi.${NC}"
        echo ""
        read -p "  Tekan ENTER untuk kembali..."
        exit 1
    fi

    chown -R www-data:www-data "$ORDERVPN_DIR"
    chmod -R 755 "$ORDERVPN_DIR"
    _ok "Permission sudah diset"
}

# ─── Setup Database MySQL ────────────────────────────────────
setup_database() {
    _step "Setup database MySQL..."

    # Generate password random untuk DB
    local DB_PASS
    DB_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)

    # Pastikan mysql jalan
    systemctl start mysql 2>/dev/null || systemctl start mariadb 2>/dev/null

    # Buat DB dan user
    mysql -u root 2>/dev/null <<SQLEOF >> "$LOG" 2>&1
CREATE DATABASE IF NOT EXISTS ordervpn_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'ordervpn'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ordervpn_db.* TO 'ordervpn'@'localhost';
FLUSH PRIVILEGES;
SQLEOF

    if [[ $? -ne 0 ]]; then
        _fail "Gagal buat database! Cek log: $LOG"
        return 1
    fi

    # Import schema
    if [[ -f "$ORDERVPN_DIR/database.sql" ]]; then
        mysql -u root ordervpn_db < "$ORDERVPN_DIR/database.sql" >> "$LOG" 2>&1
        _ok "Schema database berhasil diimport"
    fi

    # Simpan credentials
    cat > /root/.ordervpn_db <<EOF
DB_HOST=localhost
DB_USER=ordervpn
DB_PASS=${DB_PASS}
DB_NAME=ordervpn_db
EOF
    chmod 600 /root/.ordervpn_db

    echo "$DB_PASS"  # return ke caller
}

# ─── Generate config.php ─────────────────────────────────────
write_config() {
    local DB_PASS="$1"
    local BANK_NAME BANK_ACC BANK_HOLDER
    local APP_URL="http://${DOMAIN}/ordervpn"

    _step "Konfigurasi OrderVPN..."
    echo ""
    echo -e "  ${YELLOW}Setup rekening topup:${NC}"
    read -p "  Nama Bank    [BCA]  : " BANK_NAME;   BANK_NAME="${BANK_NAME:-BCA}"
    read -p "  No. Rekening        : " BANK_ACC
    read -p "  Nama Pemilik        : " BANK_HOLDER

    cat > "$ORDERVPN_DIR/includes/config.php" <<PHPEOF
<?php
// OrderVPN - Auto-generated config
// Generated by install-ordervpn.sh — Youzin Crabz Tunel

define('DB_HOST', 'localhost');
define('DB_USER', 'ordervpn');
define('DB_PASS', '${DB_PASS}');
define('DB_NAME', 'ordervpn_db');
define('DB_PORT', 3306);

define('APP_NAME', 'OrderVPN');
define('APP_URL', '${APP_URL}');
define('APP_VERSION', '1.0.0');

define('SESSION_LIFETIME', 86400);

define('MIN_TOPUP', 5000);
define('MAX_TOPUP', 1000000);

define('BANK_NAME', '${BANK_NAME}');
define('BANK_ACCOUNT', '${BANK_ACC}');
define('BANK_HOLDER', '${BANK_HOLDER}');

// Integrasi tunnel.sh — mode LOKAL (tidak perlu SSH)
define('TUNNEL_SCRIPT', '/root/tunnel.sh');
define('VPN_API_BRIDGE', '${API_BRIDGE}');
define('USE_LOCAL_API', true);    // true = pakai vpn-api lokal, false = pakai SSH
define('SSH_KEY_PATH', '/root/.ssh/id_rsa');

define('TG_BOT_TOKEN', '');
define('TG_CHAT_ID', '');

function getDB() {
    static \$pdo = null;
    if (\$pdo === null) {
        try {
            \$dsn = "mysql:host=" . DB_HOST . ";port=" . DB_PORT . ";dbname=" . DB_NAME . ";charset=utf8mb4";
            \$pdo = new PDO(\$dsn, DB_USER, DB_PASS, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false,
            ]);
        } catch (PDOException \$e) {
            http_response_code(500);
            die(json_encode(['success' => false, 'message' => 'Database error: ' . \$e->getMessage()]));
        }
    }
    return \$pdo;
}

function sanitize(\$input) {
    return htmlspecialchars(strip_tags(trim(\$input)), ENT_QUOTES, 'UTF-8');
}

function formatRupiah(\$amount) {
    return 'Rp ' . number_format(\$amount, 0, ',', '.');
}

function generateUUID() {
    return sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
        mt_rand(0, 0xffff), mt_rand(0, 0xffff),
        mt_rand(0, 0xffff),
        mt_rand(0, 0x0fff) | 0x4000,
        mt_rand(0, 0x3fff) | 0x8000,
        mt_rand(0, 0xffff), mt_rand(0, 0xffff), mt_rand(0, 0xffff)
    );
}

function sendTelegramNotif(\$message) {
    if (empty(TG_BOT_TOKEN) || empty(TG_CHAT_ID)) return;
    \$url = "https://api.telegram.org/bot" . TG_BOT_TOKEN . "/sendMessage";
    \$data = ['chat_id' => TG_CHAT_ID, 'text' => \$message, 'parse_mode' => 'HTML'];
    \$ch = curl_init();
    curl_setopt_array(\$ch, [
        CURLOPT_URL => \$url,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => http_build_query(\$data),
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 5,
    ]);
    curl_exec(\$ch);
    curl_close(\$ch);
}

function requireLogin() {
    if (session_status() === PHP_SESSION_NONE) session_start();
    if (!isset(\$_SESSION['user_id'])) {
        header('Location: /ordervpn/');
        exit;
    }
    return \$_SESSION;
}

function requireAdmin() {
    \$session = requireLogin();
    if (\$session['role'] !== 'admin') {
        header('Location: /ordervpn/dashboard.php');
        exit;
    }
    return \$session;
}
PHPEOF
    _ok "config.php berhasil digenerate"
}

# ─── Deploy vpn-api bridge (inti sinkronisasi) ───────────────
deploy_api_bridge() {
    _step "Deploy API Bridge (vpn-api)..."
    cat > "$API_BRIDGE" <<'APIEOF'
#!/bin/bash
# ============================================================
#  vpn-api — Jembatan antara OrderVPN web dan tunnel.sh
#  Dipanggil oleh PHP via shell_exec / proc_open
#  Bukan SSH — langsung di server yang sama
#  Author : The Professor
# ============================================================
TUNNEL_SH="/root/tunnel.sh"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
AKUN_DIR="/root/akun"
PUBLIC_HTML="/var/www/html"

# Load fungsi dari tunnel.sh tanpa menjalankan main_menu
# Kita source hanya bagian fungsi-nya
source_tunnel() {
    export VPN_MENU_RUNNING=1          # Supaya tidak auto-launch menu
    # Jalankan fungsi dari tunnel.sh menggunakan bash -c
    bash "$TUNNEL_SH" "${@}" 2>&1
}

ACTION="$1"
PROTOCOL="$2"
USERNAME="$3"
DAYS="$4"
QUOTA="${5:-100}"
IPLIMIT="${6:-1}"

case "$ACTION" in
    # ── CREATE ACCOUNT ────────────────────────────────────────
    create)
        [[ -z "$USERNAME" || -z "$DAYS" || -z "$PROTOCOL" ]] && {
            echo '{"success":false,"message":"Parameter tidak lengkap"}'
            exit 1
        }

        # Cek duplikat username
        if grep -q "\"email\":\"${USERNAME}\"" "$XRAY_CONFIG" 2>/dev/null; then
            echo '{"success":false,"message":"Username sudah ada"}'
            exit 1
        fi
        if [[ "$PROTOCOL" == "ssh" ]] && id "$USERNAME" >/dev/null 2>&1; then
            echo '{"success":false,"message":"Username SSH sudah ada"}'
            exit 1
        fi

        # Buat UUID
        UUID=$(cat /proc/sys/kernel/random/uuid)
        EXP=$(date -d "+${DAYS} days" +"%d %b, %Y")
        CREATED=$(date +"%d %b, %Y")
        IP_VPS=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
        DOMAIN=$(cat /etc/xray/domain 2>/dev/null | tr -d '\n\r' | xargs)

        # ── SSH ────────────────────────────────────────────────
        if [[ "$PROTOCOL" == "ssh" ]]; then
            EXP_DATE=$(date -d "+${DAYS} days" +"%Y-%m-%d")
            useradd -M -s /bin/false -e "$EXP_DATE" "$USERNAME" 2>/dev/null
            echo "${USERNAME}:${UUID:0:12}" | chpasswd 2>/dev/null
            PASSWORD="${UUID:0:12}"
            mkdir -p "$AKUN_DIR"
            printf "UUID=%s\nQUOTA=%s\nIPLIMIT=%s\nEXPIRED=%s\nCREATED=%s\n" \
                "$PASSWORD" "$QUOTA" "$IPLIMIT" "$EXP" "$CREATED" \
                > "$AKUN_DIR/ssh-${USERNAME}.txt"
            # Output JSON untuk PHP
            echo "{\"success\":true,\"protocol\":\"ssh\",\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"ip\":\"${IP_VPS}\",\"domain\":\"${DOMAIN}\",\"expired\":\"${EXP}\",\"link_config\":\"ssh://\"}"
            exit 0
        fi

        # ── XRAY (VMess / VLess / Trojan) ─────────────────────
        TEMP=$(mktemp)
        if [[ "$PROTOCOL" == "vmess" ]]; then
            jq --arg uuid "$UUID" --arg email "$USERNAME" \
               '(.inbounds[] | select(.tag | startswith("vmess")).settings.clients) += [{"id":$uuid,"email":$email,"alterId":0}]' \
               "$XRAY_CONFIG" > "$TEMP" 2>/dev/null
        elif [[ "$PROTOCOL" == "vless" ]]; then
            jq --arg uuid "$UUID" --arg email "$USERNAME" \
               '(.inbounds[] | select(.tag | startswith("vless")).settings.clients) += [{"id":$uuid,"email":$email}]' \
               "$XRAY_CONFIG" > "$TEMP" 2>/dev/null
        elif [[ "$PROTOCOL" == "trojan" ]]; then
            jq --arg password "$UUID" --arg email "$USERNAME" \
               '(.inbounds[] | select(.tag | startswith("trojan")).settings.clients) += [{"password":$password,"email":$email}]' \
               "$XRAY_CONFIG" > "$TEMP" 2>/dev/null
        fi

        if [[ $? -ne 0 ]] || [[ ! -s "$TEMP" ]]; then
            rm -f "$TEMP"
            echo '{"success":false,"message":"Gagal update Xray config (jq error)"}'
            exit 1
        fi

        if ! jq empty "$TEMP" 2>/dev/null; then
            rm -f "$TEMP"
            echo '{"success":false,"message":"Xray config JSON tidak valid"}'
            exit 1
        fi

        mv "$TEMP" "$XRAY_CONFIG"
        chmod 644 "$XRAY_CONFIG" 2>/dev/null

        if ! xray -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
            echo '{"success":false,"message":"Xray config test gagal setelah update"}'
            exit 1
        fi

        systemctl restart xray >/dev/null 2>&1
        sleep 1

        # Simpan info akun
        mkdir -p "$AKUN_DIR"
        printf "UUID=%s\nQUOTA=%s\nIPLIMIT=%s\nEXPIRED=%s\nCREATED=%s\n" \
            "$UUID" "$QUOTA" "$IPLIMIT" "$EXP" "$CREATED" \
            > "$AKUN_DIR/${PROTOCOL}-${USERNAME}.txt"

        # Build link config
        LINK_TLS="" LINK_NONTLS="" LINK_GRPC=""
        if [[ "$PROTOCOL" == "vmess" ]]; then
            J_TLS=$(printf '{"v":"2","ps":"%s","add":"bug.com","port":"443","id":"%s","aid":"0","net":"ws","path":"/vmess","type":"none","host":"%s","tls":"tls"}' "$USERNAME" "$UUID" "$DOMAIN")
            LINK_TLS="vmess://$(printf '%s' "$J_TLS" | base64 -w 0)"
            J_NONTLS=$(printf '{"v":"2","ps":"%s","add":"bug.com","port":"80","id":"%s","aid":"0","net":"ws","path":"/vmess","type":"none","host":"%s","tls":"none"}' "$USERNAME" "$UUID" "$DOMAIN")
            LINK_NONTLS="vmess://$(printf '%s' "$J_NONTLS" | base64 -w 0)"
            J_GRPC=$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","net":"grpc","path":"vmess-grpc","type":"none","host":"bug.com","tls":"tls"}' "$USERNAME" "$DOMAIN" "$UUID")
            LINK_GRPC="vmess://$(printf '%s' "$J_GRPC" | base64 -w 0)"
        elif [[ "$PROTOCOL" == "vless" ]]; then
            LINK_TLS="vless://${UUID}@bug.com:443?path=%2Fvless&security=tls&encryption=none&host=${DOMAIN}&type=ws&sni=${DOMAIN}#${USERNAME}-TLS"
            LINK_NONTLS="vless://${UUID}@bug.com:80?path=%2Fvless&security=none&encryption=none&host=${DOMAIN}&type=ws#${USERNAME}-NonTLS"
            LINK_GRPC="vless://${UUID}@${DOMAIN}:443?mode=gun&security=tls&encryption=none&type=grpc&serviceName=vless-grpc&sni=bug.com#${USERNAME}-gRPC"
        elif [[ "$PROTOCOL" == "trojan" ]]; then
            LINK_TLS="trojan://${UUID}@bug.com:443?path=%2Ftrojan&security=tls&host=${DOMAIN}&type=ws&sni=${DOMAIN}#${USERNAME}-TLS"
            LINK_NONTLS="trojan://${UUID}@bug.com:80?path=%2Ftrojan&security=none&host=${DOMAIN}&type=ws#${USERNAME}-NonTLS"
            LINK_GRPC="trojan://${UUID}@${DOMAIN}:443?mode=gun&security=tls&type=grpc&serviceName=trojan-grpc&sni=bug.com#${USERNAME}-gRPC"
        fi

        # Buat file .txt download (sesuai format tunnel.sh asli)
        mkdir -p "$PUBLIC_HTML"
        cat > "$PUBLIC_HTML/${PROTOCOL}-${USERNAME}.txt" <<DLEOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  YOUZIN CRABZ TUNEL - ${PROTOCOL^^} Account
  The Professor
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Username         : ${USERNAME}
 IP VPS           : ${IP_VPS}
 Domain           : ${DOMAIN}
 UUID/Password    : ${UUID}
 Quota            : ${QUOTA} GB
 IP Limit         : ${IPLIMIT} IP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Link TLS         :
 ${LINK_TLS}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Link NonTLS      :
 ${LINK_NONTLS}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Link gRPC        :
 ${LINK_GRPC}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Download         : http://${IP_VPS}:81/${PROTOCOL}-${USERNAME}.txt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Aktif Selama     : ${DAYS} Hari
 Dibuat Pada      : ${CREATED}
 Berakhir Pada    : ${EXP}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DLEOF

        # JSON output untuk PHP (link_config = TLS link)
        LINK_ESCAPED=$(printf '%s' "$LINK_TLS" | sed 's/"/\\"/g')
        printf '{"success":true,"protocol":"%s","username":"%s","uuid":"%s","ip":"%s","domain":"%s","expired":"%s","link_tls":"%s","link_nontls":"%s","link_grpc":"%s","download":"http://%s:81/%s-%s.txt"}\n' \
            "$PROTOCOL" "$USERNAME" "$UUID" "$IP_VPS" "$DOMAIN" "$EXP" \
            "$LINK_TLS" "$LINK_NONTLS" "$LINK_GRPC" \
            "$IP_VPS" "$PROTOCOL" "$USERNAME"
        exit 0
        ;;

    # ── DELETE ACCOUNT ────────────────────────────────────────
    delete)
        [[ -z "$PROTOCOL" || -z "$USERNAME" ]] && {
            echo '{"success":false,"message":"Parameter tidak lengkap"}'
            exit 1
        }
        if [[ "$PROTOCOL" == "ssh" ]]; then
            userdel -f "$USERNAME" 2>/dev/null
        else
            TEMP=$(mktemp)
            jq --arg email "$USERNAME" \
               'del(.inbounds[].settings.clients[]? | select(.email == $email))' \
               "$XRAY_CONFIG" > "$TEMP" 2>/dev/null
            if [[ -s "$TEMP" ]] && jq empty "$TEMP" 2>/dev/null; then
                mv "$TEMP" "$XRAY_CONFIG"
                xray -test -config "$XRAY_CONFIG" >/dev/null 2>&1 && \
                    systemctl restart xray >/dev/null 2>&1
            else
                rm -f "$TEMP"
            fi
        fi
        rm -f "$AKUN_DIR/${PROTOCOL}-${USERNAME}.txt"
        rm -f "$PUBLIC_HTML/${PROTOCOL}-${USERNAME}.txt"
        rm -f "$PUBLIC_HTML/${PROTOCOL}-${USERNAME}-clash.yaml"
        echo '{"success":true,"message":"Akun berhasil dihapus"}'
        exit 0
        ;;

    # ── CEK STATUS ────────────────────────────────────────────
    status)
        XRAY_UP=$(systemctl is-active xray 2>/dev/null)
        NGINX_UP=$(systemctl is-active nginx 2>/dev/null)
        HAPROXY_UP=$(systemctl is-active haproxy 2>/dev/null)
        DOMAIN=$(cat /etc/xray/domain 2>/dev/null | tr -d '\n\r' | xargs)
        IP_VPS=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
        printf '{"xray":"%s","nginx":"%s","haproxy":"%s","domain":"%s","ip":"%s"}\n' \
            "$XRAY_UP" "$NGINX_UP" "$HAPROXY_UP" "$DOMAIN" "$IP_VPS"
        exit 0
        ;;

    # ── LIST ACCOUNTS ─────────────────────────────────────────
    list)
        [[ -z "$PROTOCOL" ]] && PROTOCOL="*"
        echo "["
        FIRST=1
        shopt -s nullglob
        for f in "$AKUN_DIR"/${PROTOCOL}-*.txt; do
            [[ ! -f "$f" ]] && continue
            FNAME=$(basename "$f" .txt)
            PROTO="${FNAME%%-*}"
            UNAME="${FNAME#*-}"
            EXP_INFO=$(grep "EXPIRED=" "$f" 2>/dev/null | cut -d= -f2-)
            UUID_INFO=$(grep "UUID=" "$f" 2>/dev/null | cut -d= -f2-)
            [[ $FIRST -eq 0 ]] && echo ","
            printf '{"protocol":"%s","username":"%s","expired":"%s","uuid":"%s"}' \
                "$PROTO" "$UNAME" "$EXP_INFO" "$UUID_INFO"
            FIRST=0
        done
        shopt -u nullglob
        echo ""
        echo "]"
        exit 0
        ;;

    *)
        echo '{"success":false,"message":"Action tidak dikenal. Gunakan: create|delete|status|list"}'
        exit 1
        ;;
esac
APIEOF

    chmod +x "$API_BRIDGE"
    _ok "vpn-api bridge dipasang di $API_BRIDGE"
}

# ─── Deploy vpn_manager.php yang dimodifikasi untuk lokal ────
deploy_vpn_manager() {
    _step "Deploy vpn_manager.php (mode lokal)..."
    cat > "$ORDERVPN_DIR/includes/vpn_manager.php" <<'PHPEOF'
<?php
// ============================================================
// OrderVPN - VPN Manager (Mode Lokal — tanpa SSH)
// Komunikasi lewat vpn-api bridge langsung di server
// Author : The Professor
// ============================================================

require_once __DIR__ . '/config.php';

class VPNManager {

    /**
     * Buat akun VPN baru — memanggil vpn-api bridge secara lokal
     */
    public static function createAccount($server, $type, $username, $days, $quota = 100, $iplimit = 1) {

        // Sanitize input
        $username = preg_replace('/[^a-zA-Z0-9_\-]/', '', $username);
        if (empty($username)) return ['success' => false, 'message' => 'Username tidak valid'];

        if (!in_array(strtolower($type), ['ssh', 'vmess', 'vless', 'trojan'])) {
            return ['success' => false, 'message' => 'Tipe VPN tidak didukung'];
        }

        // Mode lokal: pakai vpn-api bridge langsung
        if (defined('USE_LOCAL_API') && USE_LOCAL_API && defined('VPN_API_BRIDGE')) {
            return self::callLocalAPI('create', $type, $username, $days, $quota, $iplimit);
        }

        // Fallback: SSH ke remote server
        return self::callSSH($server, $type, $username, $days, $quota, $iplimit);
    }

    /**
     * Panggil vpn-api lokal (tidak perlu SSH)
     */
    private static function callLocalAPI($action, $type, $username, $days = 0, $quota = 100, $iplimit = 1) {
        $bridge = VPN_API_BRIDGE;

        // Pastikan bridge bisa dieksekusi
        if (!is_executable($bridge)) {
            return ['success' => false, 'message' => "vpn-api bridge tidak ditemukan di $bridge"];
        }

        // Build command — semua argumen di-escape
        $cmd = sprintf(
            '%s %s %s %s %d %d %d 2>&1',
            escapeshellcmd($bridge),
            escapeshellarg($action),
            escapeshellarg(strtolower($type)),
            escapeshellarg($username),
            (int)$days,
            (int)$quota,
            (int)$iplimit
        );

        $output = shell_exec($cmd);

        if (empty($output)) {
            return ['success' => false, 'message' => 'Tidak ada output dari vpn-api'];
        }

        $result = json_decode(trim($output), true);

        if (!is_array($result)) {
            return ['success' => false, 'message' => 'Output tidak valid: ' . substr($output, 0, 200)];
        }

        // Normalisasi field untuk kompatibilitas dengan create_order.php
        if (!empty($result['success'])) {
            $result['link_config'] = $result['link_tls'] ?? $result['link_config'] ?? '';
            $result['uuid']        = $result['uuid'] ?? '';
            $result['expired']     = $result['expired'] ?? '';
        }

        return $result;
    }

    /**
     * Hapus akun VPN
     */
    public static function deleteAccount($server, $type, $username) {
        if (defined('USE_LOCAL_API') && USE_LOCAL_API) {
            $output = shell_exec(
                sprintf('%s delete %s %s 2>&1',
                    escapeshellcmd(VPN_API_BRIDGE),
                    escapeshellarg(strtolower($type)),
                    escapeshellarg($username)
                )
            );
            $result = json_decode(trim($output ?? ''), true);
            return $result ?? ['success' => false, 'message' => 'Tidak ada output'];
        }
        return self::callSSHDelete($server, $type, $username);
    }

    /**
     * Cek status server
     */
    public static function checkServerStatus($server) {
        if (defined('USE_LOCAL_API') && USE_LOCAL_API) {
            $output = shell_exec(VPN_API_BRIDGE . ' status 2>&1');
            $result = json_decode(trim($output ?? ''), true);
            return ($result['xray'] ?? '') === 'active' ? 'ready' : 'offline';
        }
        $host = $server['host'];
        $port = $server['port'] ?? 22;
        exec("nc -z -w3 {$host} {$port} 2>&1", $output, $code);
        return $code === 0 ? 'ready' : 'offline';
    }

    /**
     * Proses expired accounts — panggil cron lokal
     */
    public static function processExpiredAccounts() {
        $db = getDB();
        $stmt = $db->prepare("SELECT va.*, s.host, s.port, s.ssh_user FROM vpn_accounts va JOIN servers s ON va.server_id = s.id WHERE va.masa_aktif < CURDATE() AND va.status = 'active'");
        $stmt->execute();
        $expired = $stmt->fetchAll();

        foreach ($expired as $acc) {
            self::deleteAccount($acc, $acc['tipe'], $acc['username']);
            $db->prepare("UPDATE vpn_accounts SET status = 'expired' WHERE id = ?")->execute([$acc['id']]);
        }
        return count($expired);
    }

    // ── Fallback SSH methods ──────────────────────────────────

    private static function callSSH($server, $type, $username, $days, $quota, $iplimit) {
        $host    = $server['host'];
        $port    = $server['port'] ?? 22;
        $sshUser = $server['ssh_user'] ?? 'root';
        $sshKey  = SSH_KEY_PATH;
        $cmd = sprintf('bash %s create %s %s %d %d %d',
            TUNNEL_SCRIPT, strtolower($type), $username, $days, $quota, $iplimit);
        $sshCmd = "ssh -i {$sshKey} -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p {$port} {$sshUser}@{$host} '{$cmd}' 2>&1";
        exec($sshCmd, $output, $code);
        $out = implode("\n", $output);
        if ($code !== 0) return ['success' => false, 'message' => 'SSH gagal: ' . $out];
        return json_decode($out, true) ?? ['success' => true, 'raw_output' => $out, 'link_config' => ''];
    }

    private static function callSSHDelete($server, $type, $username) {
        $host    = $server['host'];
        $port    = $server['port'] ?? 22;
        $sshUser = $server['ssh_user'] ?? 'root';
        $sshKey  = SSH_KEY_PATH;
        $cmd = sprintf('bash %s delete %s %s', TUNNEL_SCRIPT, strtolower($type), $username);
        $sshCmd = "ssh -i {$sshKey} -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p {$port} {$sshUser}@{$host} '{$cmd}' 2>&1";
        exec($sshCmd, $output, $code);
        return ['success' => $code === 0, 'message' => implode("\n", $output)];
    }
}
PHPEOF
    _ok "vpn_manager.php (lokal) berhasil dideploy"
}

# ─── Setup Nginx vhost ───────────────────────────────────────
setup_nginx() {
    _step "Konfigurasi Nginx untuk OrderVPN..."

    # Deteksi PHP-FPM socket
    local PHP_SOCK=""
    for sock in /var/run/php/php*.fpm.sock; do
        [[ -S "$sock" ]] && { PHP_SOCK="$sock"; break; }
    done
    [[ -z "$PHP_SOCK" ]] && PHP_SOCK="unix:/var/run/php/php8.1-fpm.sock"

    # Tambahkan location ke nginx yang sudah ada (untuk VPS yang sudah punya nginx dari tunnel.sh)
    # Buat config snippet terpisah, di-include dari main config
    cat > "$ORDERVPN_CONF" <<NGINXEOF
# OrderVPN — dipasang oleh install-ordervpn.sh
# Akses: http://DOMAIN/ordervpn

server {
    listen 8080;
    listen [::]:8080;
    server_name _;
    root ${ORDERVPN_DIR};
    index index.php;
    charset utf-8;

    access_log /var/log/nginx/ordervpn_access.log;
    error_log  /var/log/nginx/ordervpn_error.log;

    # Security
    location ~ /includes/ { deny all; }
    location ~ /cron/     { deny all; }
    location ~ /\.ht      { deny all; }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass ${PHP_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 120;
    }
}
NGINXEOF

    # Enable site
    ln -sf "$ORDERVPN_CONF" /etc/nginx/sites-enabled/ordervpn 2>/dev/null

    # Test & reload nginx
    if nginx -t >> "$LOG" 2>&1; then
        systemctl reload nginx 2>/dev/null
        _ok "Nginx reload OK — OrderVPN jalan di port 8080"
    else
        _fail "Nginx config test gagal! Cek log: $LOG"
        return 1
    fi

    # Pastikan php-fpm jalan
    systemctl start php*-fpm 2>/dev/null || true
}

# ─── Setup sudoers untuk www-data ────────────────────────────
setup_permissions() {
    _step "Setup permission agar web bisa jalankan vpn-api..."

    cat > /etc/sudoers.d/ordervpn-api <<'SUDOEOF'
# OrderVPN — izinkan www-data jalankan vpn-api tanpa password
www-data ALL=(root) NOPASSWD: /usr/local/bin/vpn-api
SUDOEOF
    chmod 440 /etc/sudoers.d/ordervpn-api

    # Update vpn_manager.php agar pakai sudo saat PHP user = www-data
    # Tambahkan prefix sudo ke shell_exec di vpn_manager
    sed -i "s|escapeshellcmd(\$bridge)|'sudo ' . escapeshellcmd(\$bridge)|g" \
        "$ORDERVPN_DIR/includes/vpn_manager.php" 2>/dev/null
    sed -i "s|VPN_API_BRIDGE . ' status|'sudo ' . VPN_API_BRIDGE . ' status|g" \
        "$ORDERVPN_DIR/includes/vpn_manager.php" 2>/dev/null

    _ok "Sudoers dikonfigurasi"
}

# ─── Setup cron expire ───────────────────────────────────────
setup_cron() {
    _step "Setup cron job auto-expire akun..."
    local cronline="0 1 * * * php ${ORDERVPN_DIR}/cron/expire_accounts.php >> /var/log/ordervpn_cron.log 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "ordervpn"; then
        (crontab -l 2>/dev/null; echo "$cronline") | crontab -
        _ok "Cron job ditambahkan"
    else
        _ok "Cron job sudah ada"
    fi
}

# ─── Update server lokal di database ─────────────────────────
setup_local_server() {
    _step "Update data server lokal di database..."
    local IP_VPS
    IP_VPS=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    local DB_PASS
    DB_PASS=$(grep DB_PASS /root/.ordervpn_db 2>/dev/null | cut -d= -f2)

    mysql -u ordervpn -p"$DB_PASS" ordervpn_db 2>/dev/null <<SQLEOF
-- Ganti semua server sample dengan server lokal ini
DELETE FROM servers;
INSERT INTO servers (nama_server, code_server, lokasi, harga_hari, harga_bulan, host, port, ssh_user, status)
VALUES (
    'VPS Lokal (Youzin Crabz)',
    'local1',
    'Indonesia (Lokal)',
    300,
    9000,
    '${IP_VPS}',
    22,
    'root',
    'ready'
);
SQLEOF
    _ok "Server lokal (${IP_VPS}) ditambahkan ke database"
}

# ─── Main installer ──────────────────────────────────────────
main() {
    print_header
    detect_domain

    echo -e "  ${WHITE}Domain/IP terdeteksi: ${CYAN}${DOMAIN}${NC}"
    echo ""
    echo -e "  ${YELLOW}Script ini akan:${NC}"
    echo -e "  ${DIM}1. Install PHP, MySQL (jika belum ada)${NC}"
    echo -e "  ${DIM}2. Deploy web OrderVPN ke /var/www/html/ordervpn${NC}"
    echo -e "  ${DIM}3. Pasang vpn-api bridge (sinkron dengan tunnel.sh)${NC}"
    echo -e "  ${DIM}4. Konfigurasi Nginx di port 8080${NC}"
    echo -e "  ${DIM}5. Setup database otomatis${NC}"
    echo ""
    read -p "  Lanjut install? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { echo -e "  ${YELLOW}Dibatalkan.${NC}"; exit 0; }

    echo "" > "$LOG"

    install_deps
    deploy_files
    local DB_PASS
    DB_PASS=$(setup_database)
    write_config "$DB_PASS"
    deploy_api_bridge
    deploy_vpn_manager
    setup_nginx
    setup_permissions
    setup_cron
    setup_local_server

    # ─── Summary ────────────────────────────────────────────
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  ✔  ORDERVPN BERHASIL DIINSTALL!             ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${WHITE}URL Web Panel  :${NC} ${CYAN}http://${DOMAIN}:8080/${NC}"
    echo -e "  ${WHITE}Admin Login    :${NC} admin / password"
    echo -e "  ${YELLOW}  ⚠ GANTI PASSWORD ADMIN SETELAH LOGIN!${NC}"
    echo ""
    echo -e "  ${WHITE}Database       :${NC} ordervpn_db"
    echo -e "  ${WHITE}DB Credentials :${NC} /root/.ordervpn_db"
    echo -e "  ${WHITE}API Bridge     :${NC} $API_BRIDGE"
    echo -e "  ${WHITE}Log Instalasi  :${NC} $LOG"
    echo ""
    echo -e "  ${DIM}Cara test API bridge:${NC}"
    echo -e "  ${CYAN}  vpn-api status${NC}"
    echo -e "  ${CYAN}  vpn-api create vmess testuser 30 100 1${NC}"
    echo ""
    read -p "  Tekan ENTER untuk kembali ke menu..."
}

# ─── Jika dipanggil dari menu tunnel.sh ──────────────────────
# source script ini atau langsung run: bash /root/install-ordervpn.sh
main
