#!/bin/bash
# ============================================================
#  PATCH tunnel.sh — Tambah Menu 21: Install OrderVPN Web
#  Jalankan sekali: bash patch-tunnel-ordervpn.sh
#  Author : The Professor
# ============================================================

TUNNEL="/root/tunnel.sh"
INSTALLER="/root/install-ordervpn.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

echo ""
echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${CYAN}║  PATCH tunnel.sh — Menu OrderVPN            ║${NC}"
echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

[[ $EUID -ne 0 ]] && { echo -e "${RED}Harus root!${NC}"; exit 1; }
[[ ! -f "$TUNNEL" ]] && { echo -e "${RED}tunnel.sh tidak ditemukan di $TUNNEL${NC}"; exit 1; }

# Cek apakah sudah di-patch
if grep -q "menu_ordervpn\|Install OrderVPN" "$TUNNEL" 2>/dev/null; then
    echo -e "  ${YELLOW}⚠ tunnel.sh sudah di-patch sebelumnya.${NC}"
    read -p "  Patch ulang? [y/N]: " re
    [[ "${re,,}" != "y" ]] && exit 0
fi

# ─── Backup dulu ─────────────────────────────────────────────
cp "$TUNNEL" "${TUNNEL}.bak-ordervpn-$(date +%Y%m%d%H%M%S)"
echo -e "  ${GREEN}✔${NC} Backup dibuat"

# ─── Patch 1: Tambah entri di show_menu() ────────────────────
# Cari baris "[0] Exit Panel" dan tambahkan row baru sebelum divider
python3 - <<'PYEOF'
import re, sys

with open('/root/tunnel.sh', 'r') as f:
    content = f.read()

# Target baris yang akan kita modifikasi:
# _mrow $col "19" "Port Info"        "20" "ZI VPN UDP"
old_row = '''    _mrow $col "19" "Port Info"        "20" "ZI VPN UDP"'''
new_row = '''    _mrow $col "19" "Port Info"        "20" "ZI VPN UDP"
    _mrow1 $col "21" "Install OrderVPN Web"'''

if old_row in content:
    content = content.replace(old_row, new_row, 1)
    print("OK: show_menu patched")
else:
    # Coba fallback: cari pola _mrow terakhir di blok SYSTEM CONTROL
    print("WARN: Target baris tidak ditemukan persis, coba fallback...")
    # Cari sebelum divider akhir
    old_divider = '''    _box_divider $W
    printf "  ${RED}[0]${NC}  ${WHITE}Exit Panel${NC}\\n"'''
    new_divider = '''    _mrow1 $col "21" "Install OrderVPN Web"
    _box_divider $W
    printf "  ${RED}[0]${NC}  ${WHITE}Exit Panel${NC}\\n"'''
    if old_divider in content:
        content = content.replace(old_divider, new_divider, 1)
        print("OK: show_menu patched (fallback)")
    else:
        print("FAIL: Tidak bisa patch show_menu — lakukan manual")

with open('/root/tunnel.sh', 'w') as f:
    f.write(content)
PYEOF

# ─── Patch 2: Tambah case 21 di main_menu() ─────────────────
python3 - <<'PYEOF'
with open('/root/tunnel.sh', 'r') as f:
    content = f.read()

# Target: case "20) manage_zivpn_udp ;;"
old_case = "            20) manage_zivpn_udp ;;"
new_case = """            20) manage_zivpn_udp ;;
            21) menu_ordervpn ;;"""

if old_case in content:
    content = content.replace(old_case, new_case, 1)
    print("OK: main_menu case patched")
else:
    # Fallback: tambah sebelum baris ping|PING
    old_ping = "            ping|PING) ping_check ;;"
    new_ping = """            21) menu_ordervpn ;;
            ping|PING) ping_check ;;"""
    if old_ping in content:
        content = content.replace(old_ping, new_ping, 1)
        print("OK: main_menu case patched (fallback)")
    else:
        print("FAIL: Tidak bisa patch main_menu case")

with open('/root/tunnel.sh', 'w') as f:
    f.write(content)
PYEOF

# ─── Patch 3: Tambah fungsi menu_ordervpn() ──────────────────
python3 - <<'PYEOF'
with open('/root/tunnel.sh', 'r') as f:
    content = f.read()

# Sisipkan fungsi baru sebelum "# MAIN MENU"
menu_func = '''
#================================================
# MENU ORDERVPN WEB
#================================================

menu_ordervpn() {
    while true; do
        clear; print_menu_header "ORDERVPN WEB PANEL"
        echo -e "  ${WHITE}Web panel pemesanan VPN berbasis PHP + MySQL${NC}"
        echo -e "  ${DIM}Terintegrasi langsung dengan tunnel.sh${NC}"
        echo ""

        # Cek status instalasi
        local status_web="Belum diinstall"
        local status_color="${RED}"
        if [[ -f /var/www/html/ordervpn/index.php ]]; then
            status_web="Sudah terinstall ✔"
            status_color="${GREEN}"
        fi
        echo -e "  Status   : ${status_color}${status_web}${NC}"

        if [[ -f /var/www/html/ordervpn/index.php ]]; then
            local DOMAIN_NOW
            DOMAIN_NOW=$(cat /etc/xray/domain 2>/dev/null | tr -d "\\n\\r" | xargs)
            local IP_NOW; IP_NOW=$(get_ip 2>/dev/null || hostname -I | awk "{print \\$1}")
            echo -e "  URL Web  : ${CYAN}http://${DOMAIN_NOW:-$IP_NOW}:8080/${NC}"
        fi
        echo ""
        echo -e "  ${WHITE}[1]${NC} Install / Reinstall OrderVPN"
        echo -e "  ${WHITE}[2]${NC} Test vpn-api bridge"
        echo -e "  ${WHITE}[3]${NC} Restart PHP-FPM + Nginx"
        echo -e "  ${WHITE}[4]${NC} Lihat log instalasi"
        echo -e "  ${WHITE}[5]${NC} Uninstall OrderVPN"
        echo -e "  ${WHITE}[0]${NC} Back To Menu"
        echo ""
        read -p "  Select: " choice
        case $choice in
            1)
                if [[ -f /root/install-ordervpn.sh ]]; then
                    bash /root/install-ordervpn.sh
                else
                    echo -e "  ${RED}✘ install-ordervpn.sh tidak ditemukan di /root/${NC}"
                    echo -e "  ${YELLOW}Upload dulu: scp install-ordervpn.sh root@VPS:/root/${NC}"
                    sleep 3
                fi ;;
            2)
                clear; print_menu_header "TEST VPN-API BRIDGE"
                if command -v vpn-api >/dev/null 2>&1 || [[ -f /usr/local/bin/vpn-api ]]; then
                    echo -e "  ${CYAN}→ Cek status services:${NC}"
                    /usr/local/bin/vpn-api status 2>/dev/null || vpn-api status 2>/dev/null
                    echo ""
                    echo -e "  ${DIM}Format penggunaan:${NC}"
                    echo -e "  ${CYAN}vpn-api create vmess USERNAME DAYS QUOTA IPLIMIT${NC}"
                    echo -e "  ${CYAN}vpn-api delete vmess USERNAME${NC}"
                    echo -e "  ${CYAN}vpn-api list vmess${NC}"
                else
                    echo -e "  ${RED}vpn-api belum dipasang. Install OrderVPN dulu (opsi 1).${NC}"
                fi
                echo ""; read -p "  Press any key..." ;;
            3)
                systemctl restart php*-fpm nginx 2>/dev/null
                echo -e "  ${GREEN}✔ PHP-FPM & Nginx direstart${NC}"; sleep 2 ;;
            4)
                clear; print_menu_header "LOG INSTALASI ORDERVPN"
                if [[ -f /var/log/ordervpn-install.log ]]; then
                    tail -50 /var/log/ordervpn-install.log
                else
                    echo -e "  ${DIM}Log belum ada${NC}"
                fi
                echo ""; read -p "  Press any key..." ;;
            5)
                read -p "  Yakin uninstall OrderVPN? [y/N]: " yn
                if [[ "${yn,,}" == "y" ]]; then
                    rm -rf /var/www/html/ordervpn
                    rm -f /etc/nginx/sites-enabled/ordervpn
                    rm -f /etc/nginx/sites-available/ordervpn
                    rm -f /usr/local/bin/vpn-api
                    rm -f /etc/sudoers.d/ordervpn-api
                    mysql -u root -e "DROP DATABASE IF EXISTS ordervpn_db;" 2>/dev/null
                    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
                    echo -e "  ${GREEN}✔ OrderVPN telah diuninstall${NC}"
                    sleep 2
                fi ;;
            0) return ;;
        esac
    done
}

'''

target = "# MAIN MENU\n#================================================\n\nmain_menu()"
if target in content:
    content = content.replace(target, menu_func + target, 1)
    print("OK: menu_ordervpn() function inserted")
else:
    # Fallback: sisipkan sebelum main_menu()
    fallback = "\nmain_menu() {"
    idx = content.rfind("\nmain_menu() {")
    if idx != -1:
        content = content[:idx] + "\n" + menu_func + content[idx:]
        print("OK: menu_ordervpn() inserted (fallback)")
    else:
        print("FAIL: Tidak bisa insert menu_ordervpn()")

with open('/root/tunnel.sh', 'w') as f:
    f.write(content)
PYEOF

# ─── Pindahkan installer ke /root ────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/install-ordervpn.sh" && "$SCRIPT_DIR/install-ordervpn.sh" != "$INSTALLER" ]]; then
    cp "$SCRIPT_DIR/install-ordervpn.sh" "$INSTALLER"
    chmod +x "$INSTALLER"
    echo -e "  ${GREEN}✔${NC} install-ordervpn.sh disalin ke /root/"
fi

# ─── Validasi bash syntax ─────────────────────────────────────
if bash -n "$TUNNEL" 2>/dev/null; then
    echo -e "  ${GREEN}✔${NC} Syntax tunnel.sh OK"
else
    echo -e "  ${RED}✘ Ada syntax error di tunnel.sh setelah patch!${NC}"
    echo -e "  ${YELLOW}  Restore dari backup: cp ${TUNNEL}.bak-ordervpn-* /root/tunnel.sh${NC}"
    exit 1
fi

echo ""
echo -e "  ${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${GREEN}║  ✔  PATCH BERHASIL!                          ║${NC}"
echo -e "  ${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${WHITE}Menu baru ditambahkan:${NC} ${CYAN}[21] Install OrderVPN Web${NC}"
echo -e "  ${WHITE}Untuk membuka panel:${NC}"
echo -e "  ${CYAN}  ketik 'menu' di terminal${NC}"
echo -e "  ${CYAN}  pilih opsi 21${NC}"
echo ""
echo -e "  ${WHITE}Atau install langsung:${NC}"
echo -e "  ${CYAN}  bash /root/install-ordervpn.sh${NC}"
echo ""
