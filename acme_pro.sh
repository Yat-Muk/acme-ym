#!/bin/bash

# ==========================================
# 專業版 ACME 證書管理腳本 (v2.3)
# 基於 acme.sh 內核
# 特性：全功能覆蓋 (含撤銷/刪除/IPv6支持)
# ==========================================

# --- 變量定義 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

CERT_DIR="/root/cert"
ACME_HOME="$HOME/.acme.sh"

# --- 幫助函數 ---

log_info() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }
log_err()  { echo -e "${RED}[ERROR] $1${PLAIN}"; }

check_root() {
    [[ $EUID -ne 0 ]] && log_err "請以 root 權限運行此腳本" && exit 1
}

install_deps() {
    log_info "檢查並安裝依賴..."
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y curl socat tar cron lsof
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y curl socat tar cronie lsof
    else
        log_err "不支持的系統發行版"
        exit 1
    fi
}

install_acme_core() {
    if [[ ! -f "$ACME_HOME/acme.sh" ]]; then
        log_info "正在安裝 acme.sh 核心..."
        read -p "請輸入註冊郵箱 (回車自動生成): " user_email
        if [[ -z "$user_email" ]]; then
            auto_prefix=$(date +%s%N | md5sum | cut -c 1-6)
            user_email="${auto_prefix}@gmail.com"
        fi
        curl https://get.acme.sh | sh -s email="$user_email"
        source ~/.bashrc
    else
        log_info "acme.sh 已安裝，執行更新..."
        "$ACME_HOME"/acme.sh --upgrade --auto-upgrade
    fi
}

# --- 核心功能函數 ---

# 功能 1: 申請並安裝證書 (核心邏輯)
issue_cert_core() {
    local domain=$1
    local mode=$2 # standalone 或 dns
    local dns_type=$3 # dns_cf, dns_dp, dns_ali (僅在 mode=dns 時需要)
    
    mkdir -p "$CERT_DIR"

    # 申請邏輯
    if [[ "$mode" == "standalone" ]]; then
        # 80 端口檢測與釋放
        if lsof -i :80 | grep -q LISTEN; then
            log_warn "檢測到 80 端口被佔用："
            lsof -i :80
            # 默認直接回車(Y)即殺進程，符合你的暴力清場需求
            read -p "是否強制殺死上述進程以釋放端口？[Y/n] (默認: 是): " kill_choice
            if [[ -z "$kill_choice" || "$kill_choice" == "y" || "$kill_choice" == "Y" ]]; then
                lsof -i :80 | grep -v "PID" | awk '{print "kill -9",$2}' | sh >/dev/null 2>&1
                sleep 2
                log_info "端口已釋放。"
            else
                log_err "用戶取消，操作終止。"
                return 1
            fi
        fi

        # IPv6 檢測 (針對 Feature 1: 純 IPv6 支持)
        local listen_v6_flag=""
        if [[ -n $(ip -6 addr show scope global) ]] && [[ -z $(ip -4 addr show scope global) ]]; then
            log_warn "檢測到純 IPv6 環境，啟用 --listen-v6 模式"
            listen_v6_flag="--listen-v6"
        fi

        "$ACME_HOME"/acme.sh --issue -d "$domain" --standalone -k ec-256 --force $listen_v6_flag
    
    elif [[ "$mode" == "dns" ]]; then
        "$ACME_HOME"/acme.sh --issue --dns "$dns_type" -d "$domain" -d "*.$domain" --force
    fi

    if [[ $? -ne 0 ]]; then
        log_err "證書申請失敗，請檢查日誌。"
        return 1
    fi

    # 安裝證書 (Feature 6: 存放到 /root/cert)
    log_info "正在安裝證書..."
    "$ACME_HOME"/acme.sh --install-cert -d "$domain" \
        --key-file       "$CERT_DIR/private.key"  \
        --fullchain-file "$CERT_DIR/cert.crt" \
        --ecc

    if [[ -s "$CERT_DIR/private.key" ]]; then
        log_info "證書部署成功！"
        echo -e "公鑰: ${GREEN}$CERT_DIR/cert.crt${PLAIN}"
        echo -e "私鑰: ${GREEN}$CERT_DIR/private.key${PLAIN}"
        return 0
    else
        log_err "證書文件未生成。"
        return 1
    fi
}

menu_standalone() {
    read -p "請輸入域名: " domain
    issue_cert_core "$domain" "standalone"
}

menu_dns() {
    read -p "請輸入域名 (不要帶 *): " domain
    echo -e "1. Cloudflare\n2. 騰訊雲 (DNSPod)\n3. 阿里雲"
    read -p "選擇: " dns_select
    case "$dns_select" in
        1)
            read -p "CF API Key: " cf_key; read -p "CF Email: " cf_email
            export CF_Key="$cf_key"; export CF_Email="$cf_email"
            issue_cert_core "$domain" "dns" "dns_cf" ;;
        2)
            read -p "DNSPod ID: " dp_id; read -p "DNSPod Key: " dp_key
            export DP_Id="$dp_id"; export DP_Key="$dp_key"
            issue_cert_core "$domain" "dns" "dns_dp" ;;
        3)
            read -p "Aliyun Key: " ali_key; read -p "Aliyun Secret: " ali_secret
            export Ali_Key="$ali_key"; export Ali_Secret="$ali_secret"
            issue_cert_core "$domain" "dns" "dns_ali" ;;
        *) log_err "輸入錯誤";;
    esac
}

# Feature 4: 查詢
list_certs() {
    "$ACME_HOME"/acme.sh --list
    [[ -f "$CERT_DIR/cert.crt" ]] && echo -e "\n本地已部署: $CERT_DIR/cert.crt"
}

# Feature 4: 撤銷並刪除 (優化版：自動清理文件)
revoke_cert() {
    list_certs
    echo -e "${YELLOW}請輸入要刪除的域名 (Main_Domain 列顯示的內容)${PLAIN}"
    read -p "域名: " domain
    
    if [[ -z "$domain" ]]; then log_err "域名不能為空"; return; fi

    read -p "確定要撤銷並刪除 $domain 嗎？[y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        # 1. 撤銷證書
        "$ACME_HOME"/acme.sh --revoke -d "$domain" --ecc
        # 2. 移除記錄
        "$ACME_HOME"/acme.sh --remove -d "$domain" --ecc
        # 3. 物理刪除 /root/cert 下的文件 (這一步滿足你的「刪除」需求)
        rm -f "$CERT_DIR/cert.crt" "$CERT_DIR/private.key" "$CERT_DIR/fullchain.cer" "$CERT_DIR/$domain.key"
        
        log_info "證書已撤銷，本地文件已清理。"
    else
        log_info "已取消。"
    fi
}

# Feature 5: 手動續期
renew_certs() {
    log_info "正在續期所有證書..."
    "$ACME_HOME"/acme.sh --cron --force
}

uninstall_all() {
    read -p "確認卸載並清理環境? [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        "$ACME_HOME"/acme.sh --uninstall
        rm -rf "$ACME_HOME" "$CERT_DIR"
        sed -i '/acme.sh/d' ~/.bashrc
        log_info "卸載完成。"
    fi
}

show_menu() {
    clear
    echo -e "${BLUE}=== Acme Pro v2.3 (全功能版) ===${PLAIN}"
    echo -e " 1. 申請證書 (80端口 / DNS API)"
    echo -e " 2. 查詢證書列表"
    echo -e " 3. 刪除證書 (撤銷+清理文件)"      # 對應 Feature 4
    echo -e " 4. 手動一鍵續期"       # 對應 Feature 5
    echo -e " 5. 卸載腳本 & 清理"
    echo -e " 0. 退出"
    echo -e "${BLUE}================================${PLAIN}"
    read -p " 選擇: " num

    case "$num" in
        1)
            echo -e "1. 獨立 80 端口模式 (自動釋放端口/支持純IPv6)" # 對應 Feature 1 & 2
            echo -e "2. DNS API 模式 (支持泛域名/CF/阿里/騰訊)"     # 對應 Feature 2 & 3
            read -p "選擇: " m; [[ "$m" == "1" ]] && menu_standalone; [[ "$m" == "2" ]] && menu_dns ;;
        2) list_certs ;;
        3) revoke_cert ;;
        4) renew_certs ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) log_err "無效選擇";;
    esac
}

check_root
install_deps
install_acme_core

if [[ "$1" == "--source-only" ]]; then return 0 2>/dev/null || exit 0; fi
show_menu
