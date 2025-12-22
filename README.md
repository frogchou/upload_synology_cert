
---

# Synology DSM Certificate Uploader (LAN / WebAPI)

一个 **在局域网内通过 Synology 官方 WebAPI 自动更新 DSM 证书** 的 Linux 脚本方案，  
**不依赖公网、不依赖 acme.sh 的 Synology hook、不需要每次输入 OTP**，可安全用于 `cron` 定时任务。

---

## ✨ 项目背景与目标

在实际运维中，群晖（Synology DSM）证书管理存在几个常见痛点：

- DSM 官方 ACME 方式 **强依赖公网**
    
- acme.sh 的 `synology_dsm` hook **不透明、可控性差**
    
- 开启 2FA 后，API 自动化常常 **卡在 OTP**
    
- 每次导入证书容易 **误新增多张证书**，造成管理混乱
    

本项目的目标是：

> **在完全内网环境下，通过 DSM 官方 HTTPS WebAPI，实现证书的“自动、可重复、安全更新”，并具备工程级可维护性。**

---

## 🧠 工作原理（核心设计）

### 1️⃣ 官方 API，而非逆向接口

- 使用 **Synology 官方 WebAPI**（`/webapi/entry.cgi`）
    
- 通过 `SYNO.API.Info` 动态发现 API 路径与版本
    
- 通过 `SYNO.API.Auth` 完成登录与会话管理
    
- 通过 `SYNO.Core.Certificate.import` 上传/更新证书
    

### 2️⃣ 2FA 免 OTP 的关键机制

首次运行时：

- 使用 `otp_code + enable_device_token`
    
- DSM 返回 `device_id`
    
- 脚本自动将 `device_id` 写入 `config.txt`
    

后续运行时：

- 使用 `device_name + device_id`
    
- **无需再输入 OTP**
    
- 可安全放入 `cron`
    

### 3️⃣ 更新而不是新增（证书对象模型）

DSM 内部将证书视为“对象”：

- **不传 `id` → 新增证书**
    
- **传 `id` → 覆盖更新证书**
    

本脚本支持两种模式：

- **首次运行**：创建证书对象，并自动保存 `CERT_ID`
    
- **后续运行**：使用 `CERT_ID` 覆盖更新，不产生新证书条目
    

### 4️⃣ CSRF / Token 的兼容处理

为兼容不同 DSM 版本：

- `_sid` 与 `SynoToken` 放在 URL Query
    
- 同时在 Header 中发送 `X-SYNO-TOKEN`
    
- 避免 `error.code = 119` 等常见问题
    

---

## 📂 项目结构

```text
.
├── upload_synology_cert.sh   # 主脚本
├── config.txt                # 配置文件（账号 / 证书 / 设备信息）
└── README.md                 # 项目说明文档
```

---

## ⚙️ 运行环境要求

- Linux（任意发行版）
    
- Bash ≥ 4.x
    
- 依赖工具：
    
    - `curl`
        
    - `jq`
        
    - `openssl`
        
    - `sed`
        
    - `grep`
        

---

## 🧾 配置文件说明（config.txt）

```ini
# NAS 地址
NAS_URL=https://192.168.31.244
NAS_PORT=5001

# DSM 登录账号
USERNAME=frogchou
PASSWORD=changeme

# 2FA（首次运行需要）
OTP_CODE=123456
DEVICE_NAME=CertUploader
DEVICE_ID=

# 证书文件路径（PEM）
CERT_PATH=/home/nas/ssl/frogchou.com.cer
KEY_PATH=/home/nas/ssl/frogchou.com.key
CA_PATH=/home/nas/ssl/ca.cer

# （可选）证书描述
CERT_DESC=frogchou.com

# （自动写入）证书对象 ID，用于后续更新
CERT_ID=

# 日志目录
LOG_DIR=/var/log/syno_cert_uploader
```

### 字段说明

|字段|是否必须|说明|
|---|---|---|
|OTP_CODE|仅首次|2FA 动态码，成功后可留空|
|DEVICE_ID|自动生成|用于免 OTP 登录|
|CERT_ID|自动生成|用于“更新而不是新增”|
|CERT_PATH / KEY_PATH / CA_PATH|必须|PEM 格式证书|

---

## 🚀 使用方式

### 第一次运行（初始化）

```bash
chmod +x upload_synology_cert.sh
./upload_synology_cert.sh config.txt
```

你需要：

- 在 `config.txt` 中填写一次 `OTP_CODE`
    
- 脚本会自动：
    
    - 注册设备
        
    - 保存 `DEVICE_ID`
        
    - 创建证书并保存 `CERT_ID`
        

### 第二次及以后运行（自动更新）

```bash
./upload_synology_cert.sh config.txt
```

特点：

- ❌ 不再需要 OTP
    
- ❌ 不新增证书
    
- ✅ 只更新已有证书
    
- ✅ 可直接放入 `cron`
    

---

## ⏱️ 定时更新（cron 示例）

```bash
0 3 * * * /path/upload_synology_cert.sh /path/config.txt >> /var/log/syno_cert_cron.log 2>&1
```

---

## 📜 日志与排错

每次运行都会生成独立运行目录，例如：

```text
/var/log/syno_cert_uploader/
└── run_20251222_134911/
    ├── api_info.json
    ├── login_basic.json
    ├── login_otp.json
    ├── cert_import.json
    └── *.raw
```

- `.json`：格式化后的 API 响应
    
- `.raw`：原始返回（用于定位 DSM 行为差异）
    

---

## 🔐 安全建议（强烈推荐）

- 建议创建 **专用 DSM 账号**：
    
    - 仅授予“证书管理”权限
        
- 保留 2FA，但使用 device token
    
- 不在脚本中硬编码敏感信息（可配合 `.env` / vault）
    

---

## ❓ 常见问题

### Q: 为什么不用 acme.sh 的 synology hook？

- 不透明
    
- 难以调试
    
- 不适合复杂内网 / 多证书策略
    

### Q: 为什么 DSM 会允许同域名多张证书？

- DSM 证书是“对象”，不是“域名唯一”
    
- 必须显式指定 `id` 才是更新
    

### Q: 支持 RSA / ECC 吗？

- 支持（由你提供的证书格式决定）
    

---

## 🧩 可扩展方向

- 自动清理历史旧证书
    
- 多域名 / SAN 证书轮换
    
- 证书更新后自动绑定服务
    
- 与 ACME 客户端解耦（作为统一发布器）
    

---

## 📄 License

MIT License  

---
