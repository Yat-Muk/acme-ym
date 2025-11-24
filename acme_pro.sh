#!/bin/bash

# ==========================================
# Acme Pro v3.3
# ==========================================

# --- 1. UI 與配色定義 ---
export LANG=en_US.UTF-8
red='\033[0;31m'
bblue='\033[0;34m'
plain='\033[0m'
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# --- 2. 核心變量 ---
CERT_DIR="/root/cert"
ACME_HOME="$HOME/.acme.sh"
SCRIPT_PATH="/root/acme_pro.sh"

# --- 3. 基礎功能 ---
check_root() {
    [[ $EUID -ne 0 ]] && red "請以root模式運行腳本" && exit 1
}

install_deps() {
    local deps_missing=0
    for cmd in curl socat cron lsof tar; do
        if ! command -v $cmd &> /dev/null; then
            deps_missing=1
        fi
    done

    if [ $deps_missing -eq 1 ]; then
        green "發現缺失依賴，正在安裝..."
        if [ -f /etc/debian_version ]; then
            apt update -y >/dev/null 2>&1
            apt install -y curl socat tar cron lsof >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y epel-release >/dev/null 2>&1
            yum install -y curl socat tar cronie lsof >/dev/null 2>&1
        else
            red "不支持當前的系統，請使用 Debian/Ubuntu/CentOS" && exit 1
        fi
        green "依賴安裝完成。"
    fi
}

create_shortcut() {
    if [[ ! -f "$SCRIPT_PATH" ]] && [[ -f "$0" ]]; then
        cp "$0" "$SCRIPT_PATH"
    fi
    if [[ -f "$SCRIPT_PATH" ]] && [[ ! -f /usr/bin/ac ]]; then
        chmod +x "$SCRIPT_PATH"
        ln -sf "$SCRIPT_PATH" /usr/bin/ac
        green "快捷命令已創建！以後輸入 'ac' 即可進入菜單。"
        sleep 1
    fi
}

install_acme_core() {
    if [[ ! -f "$ACME_HOME/acme.sh" ]]; then
        green "正在安裝 acme.sh 核心..."
        readp "請輸入註冊所需的郵箱（回車跳過則自動生成虛擬gmail郵箱）：" Aemail
        if [ -z "$Aemail" ]; then
            auto_prefix=$(date +%s%N | md5sum | cut -c 1-6)
            Aemail="${auto_prefix}@gmail.com"
        fi
        yellow "當前註冊的郵箱名稱：$Aemail"
        curl https://get.acme.sh | sh -s email="$Aemail"
        source ~/.bashrc
    else
        "$ACME_HOME"/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    fi
}

# --- 4. 業務邏輯 (內核) ---

check_domain_consistency() {
    local domain=$1
    green "正在進行域名 IP 安全檢測..."
    
    local local_v4=$(curl -s4m5 https://api.ip.sb/ip -k)
    local local_v6=$(curl -s6m5 https://api.ip.sb/ip -k)
    local domain_ips=$(getent hosts "$domain" | awk '{print $1}')
    
    if [[ -z "$domain_ips" ]]; then
        red "錯誤：無法解析域名 $domain，請檢查 DNS 設置。"
        return 1
    fi

    local match_found=0
    for ip in $domain_ips; do
        if [[ -n "$local_v4" && "$ip" == "$local_v4" ]]; then match_found=1; fi
        if [[ -n "$local_v6" && "$ip" == "$local_v6" ]]; then match_found=1; fi
    done

    if [[ $match_found -eq 1 ]]; then
        green "檢測通過：域名 IP 與本機 IP 一致。"
        return 0
    else
        echo
        red "=========================================="
        red " [警告] 域名解析 IP 與本機 IP 不一致！"
        red "=========================================="
        echo -e " 域名 ($domain) 解析 IP :\n${yellow}${domain_ips}${plain}"
        echo -e " 本機 IP (IPv4)        : ${yellow}${local_v4:-未檢測到}${plain}"
        echo -e " 本機 IP (IPv6)        : ${yellow}${local_v6:-未檢測到}${plain}"
        echo
        yellow "可能原因："
        echo "1. 域名開啟了 CDN (如 Cloudflare 小黃雲) -> 若確認，請強制繼續"
        echo "2. 域名 DNS 尚未生效或填寫錯誤 -> 請取消並檢查"
        echo "3. 本機位於 NAT 內網 (如 AWS/GCP/Oracle) -> 若確認，請強制繼續"
        echo
        readp "是否強制繼續申請？[y/N] (默認 N): " force_choice
        if [[ "$force_choice" == "y" || "$force_choice" == "Y" ]]; then
            yellow "用戶選擇強制繼續操作..."
            return 0
        else
            red "操作已取消，請檢查 DNS 設置。"
            return 1
        fi
    fi
}

get_current_cert_info() {
    if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        local main_domain=$(bash ~/.acme.sh/acme.sh --list | grep -v "Main_Domain" | head -n 1 | awk '{print $1}')
        if [[ -n "$main_domain" ]] && [[ -f "$CERT_DIR/cert.crt" ]] && [[ -s "$CERT_DIR/cert.crt" ]]; then
            current_cert="$main_domain"
        else
            current_cert='無證書申請記錄'
        fi
    else
        current_cert='未安裝 acme.sh'
    fi
}

issue_cert_core() {
    local domain=$1
    local mode=$2
    local dns_type=$3
    
    mkdir -p "$CERT_DIR"

    check_domain_consistency "$domain"
    if [[ $? -ne 0 ]]; then return 1; fi

    if [[ "$mode" == "standalone" ]]; then
        if lsof -i :80 | grep -q LISTEN; then
            yellow "檢測到 80 端口被佔用！"
            readp "是否強制釋放 80 端口？[Y/n] (默認Y): " kill_choice
            if [[ -z "$kill_choice" || "$kill_choice" == "y" || "$kill_choice" == "Y" ]]; then
                lsof -i :80 | grep -v "PID" | awk '{print "kill -9",$2}' | sh >/dev/null 2>&1
                sleep 2
                green "80 端口已釋放！"
            else
                red "用戶取消操作。" && return 1
            fi
        fi

        local listen_v6_flag=""
        if [[ -n $(ip -6 addr show scope global) ]] && [[ -z $(ip -4 addr show scope global) ]]; then
            yellow "檢測到純 IPv6 環境，啟用 --listen-v6 模式"
            listen_v6_flag="--listen-v6"
        fi

        "$ACME_HOME"/acme.sh --issue -d "$domain" --standalone -k ec-256 --force $listen_v6_flag
    
    elif [[ "$mode" == "dns" ]]; then
        "$ACME_HOME"/acme.sh --issue --dns "$dns_type" -d "$domain" -d "*.$domain" --force
    fi

    if [[ $? -ne 0 ]]; then
        red "證書申請失敗！請檢查報錯信息。"
        return 1
    fi

    green "正在安裝證書到 $CERT_DIR ..."
    "$ACME_HOME"/acme.sh --install-cert -d "$domain" \
        --key-file       "$CERT_DIR/private.key"  \
        --fullchain-file "$CERT_DIR/cert.crt" \
        --ecc

    if [[ -s "$CERT_DIR/private.key" ]]; then
        green "證書申請成功！"
        yellow "公鑰: $CERT_DIR/cert.crt"
        yellow "密鑰: $CERT_DIR/private.key"
        return 0
    else
        red "證書安裝失敗。"
        return 1
    fi
}

# --- 5. 菜單動作 ---

action_apply_standalone() {
    readp "請輸入解析完成的域名: " ym
    green "域名: $ym" && sleep 1
    issue_cert_core "$ym" "standalone"
}

action_apply_dns() {
    readp "請輸入主域名 (不要帶*): " ym
    green "域名: $ym" && sleep 1
    
    echo -e "請選擇 DNS 服務商：\n1.Cloudflare\n2.騰訊雲DNSPod\n3.阿里雲Aliyun"
    readp "請選擇：" cd
    case "$cd" in 
        1 )
            readp "Cloudflare Global API Key：" GAK; export CF_Key="$GAK"
            readp "Cloudflare Email：" CFemail; export CF_Email="$CFemail"
            issue_cert_core "$ym" "dns" "dns_cf" ;;
        2 )
            readp "DNSPod ID：" DPID; export DP_Id="$DPID"
            readp "DNSPod Key：" DPKEY; export DP_Key="$DPKEY"
            issue_cert_core "$ym" "dns" "dns_dp" ;;
        3 )
            readp "Aliyun Key：" ALKEY; export Ali_Key="$ALKEY"
            readp "Aliyun Secret：" ALSER; export Ali_Secret="$ALSER"
            issue_cert_core "$ym" "dns" "dns_ali" ;;
        * ) red "輸入錯誤" && exit 1 ;;
    esac
}

action_apply_menu() {
    echo
    ab="1.獨立80端口模式 (需域名解析到本機，自動釋放80端口)\n2.DNS API模式 (需API Key，支持泛域名，自動續期)\n0.返回上一層\n 請選擇："
    readp "$ab" cd
    case "$cd" in 
        1 ) action_apply_standalone ;;
        2 ) action_apply_dns ;;
        0 ) show_menu ;;
        * ) red "選擇錯誤" && show_menu ;;
    esac
}

action_list_certs() {
    green "當前證書列表："
    bash ~/.acme.sh/acme.sh --list
    echo
    if [[ -f "$CERT_DIR/cert.crt" ]]; then
        blue "本地文件路徑 ($CERT_DIR):"
        ls -lh "$CERT_DIR/"
    fi
}

action_revoke_delete() {
    action_list_certs
    readp "請輸入要刪除的域名 (Main_Domain): " ym
    if [[ -z "$ym" ]]; then red "域名不能為空"; return; fi

    readp "確定要刪除 $ym 嗎？(含文件清理) [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        "$ACME_HOME"/acme.sh --revoke -d "$ym" --ecc
        "$ACME_HOME"/acme.sh --remove -d "$ym" --ecc
        rm -f "$CERT_DIR/cert.crt" "$CERT_DIR/private.key" "$CERT_DIR/fullchain.cer" "$CERT_DIR/$ym.key"
        green "已撤銷並刪除。"
    else
        yellow "已取消。"
    fi
}

action_renew() {
    green "正在強制續期..."
    "$ACME_HOME"/acme.sh --cron --force
    green "續期完成。"
}

action_uninstall() {
    readp "確定要卸載腳本並清理證書嗎？[y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        "$ACME_HOME"/acme.sh --uninstall
        # 修改點：卸載同時刪除 /usr/bin/ac 和舊的 /usr/bin/acme
        rm -rf "$ACME_HOME" "$CERT_DIR" "/usr/bin/ac" "/usr/bin/acme"
        sed -i '/acme.sh/d' ~/.bashrc
        green "卸載完成。"
    else
        yellow "已取消。"
    fi
}

# --- 6. 主菜單 ---
show_menu() {
    clear
    check_root
    create_shortcut
    install_deps
    install_acme_core
    get_current_cert_info

    green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"           
    echo -e "${bblue}   Acme Pro Script (v3.3)          ${plain}"
    echo -e "${bblue}   快捷命令: 輸入 ac 即可再次運行    ${plain}"
    green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
    echo
    red "========================================================================="
    blue "當前已申請證書："
    yellow "$current_cert"
    echo
    red "========================================================================="
    green " 1. 申請證書 (80端口 / DNS API) "
    green " 2. 查詢證書列表 "
    green " 3. 刪除證書 "
    green " 4. 續期證書 "
    green " 5. 卸載腳本 "
    green " 0. 退出 "
    echo
    readp "請輸入數字:" NumberInput
    case "$NumberInput" in     
        1 ) action_apply_menu ;;
        2 ) action_list_certs ;;
        3 ) action_revoke_delete ;;
        4 ) action_renew ;;
        5 ) action_uninstall ;;
        0 ) exit 0 ;;
        * ) red "輸入無效" && sleep 1 && show_menu ;;
    esac
}

# --- 7. 入口 ---
if [[ ! -f "$SCRIPT_PATH" ]] && [[ -f "$0" ]]; then
    cp "$0" "$SCRIPT_PATH"
fi

if [[ "$1" == "--source-only" ]]; then return 0 2>/dev/null || exit 0; fi
show_menu
