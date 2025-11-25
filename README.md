-----

# 🚀 Acme Pro Script (ACME 證書管理專業版)

![License](https://img.shields.io/github/license/Yat-Muk/acme-ym?style=flat-square&label=License)
![Language](https://img.shields.io/badge/Language-Bash-blue.svg?style=flat-square)

安全、穩定、高效的 `acme.sh` 封裝腳本。修復了常見一鍵安裝腳本中存在的暴力端口釋放和 IP 檢測不兼容等 UX 缺陷。

## ✨ 核心特色 (Features)

  * **🌍 網絡兼容性**：原生支持純 **IPv4、純 IPv6** 及雙棧 VPS 環境。
  * **模式全面**：支持 Standalone (80 端口) 和 DNS API 兩種模式，且均支持單域名與**泛域名**申請。
  * **服務商覆蓋**：原生支持 Cloudflare, 騰訊雲 DNSPod, 阿里雲 Aliyun 等主流 DNS API 服務商。
  * **完整生命週期管理**：提供證書查詢、**撤銷**、本地文件清理的完整管理流程。
  * **續期保護**：手動續期前會顯示證書狀態，並詢問是否強制執行，避免觸發 CA 限制。
  * **🛡️ IP 安全屏障**：內建域名/本機 IP 一致性強制檢測，防止因 DNS 解析錯誤導致證書申請失敗或誤發。
  * **🔑 自動化集成**：申請成功的域名會自動寫入 `/root/cert/ca.log`，便於上游配置腳本直接調用。

## 💡 快速開始 (Quick Start)

### 1\. 安裝與啟動 (一鍵式)

只需執行以下命令，腳本會自動完成依賴安裝、Acme 核心部署，並創建快捷指令。

```bash
wget -O /root/acme_pro.sh https://raw.githubusercontent.com/Yat-Muk/acme-ym/master/acme_pro.sh && chmod +x /root/acme_pro.sh && bash /root/acme_pro.sh
```

### 2\. 重啟後運行

安裝成功後，只需輸入快捷指令即可：

```bash
ac-pro
```

## ⚙️ 證書路徑 (Path)

所有證書 (cert.crt 和 private.key) 統一安裝在：

```
/root/cert/
```

當前申請的主域名會寫入日誌：

```
/root/cert/ca.log
```

## 📜 許可證 (License)

本專案基於 **GPL-3.0 License** 發佈，以確保所有使用者都能自由使用、修改和分享。
