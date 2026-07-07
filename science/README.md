# 网络工具

> 本工具不包含在根目录 `install.sh` 一键部署流程中；如有需要，请手动进入本目录执行安装脚本。

> **协议**: VLESS + XTLS-Vision + Reality
> **伪装目标**: www.microsoft.com
> **部署方式**: Xray 二进制，直连

---

## 为什么选择 Reality？

| 特性 | 传统 WS+TLS | VLESS + Reality |
|------|:---:|:---:|
| 需要域名 | ✅ | ❌ 不需要 |
| 需要 SSL 证书 | ✅ | ❌ 不需要 |
| 被主动探测风险 | 中 | 极低 |
| 延迟 | 中 | 极低 |
| 抗封锁 | ⭐⭐ | ⭐⭐⭐⭐⭐ |

Reality 通过 X25519 密钥对动态复现目标站点（如 microsoft.com）的 TLS 握手特征，主动探测时返回真实证书，无法区分代理和正常流量。

---

## 快速部署

```bash
cd science
chmod +x install.sh
sudo ./install.sh
```

### 前置条件

- Root 权限
- 境外 VPS（Debian / Ubuntu / CentOS）
- **无需域名、无需 SSL 证书**

### 脚本做了什么

1. 安装 Xray-core 最新版
2. 生成 X25519 密钥对（Reality 核心）
3. 生成 random UUID + shortId
4. 配置 VLESS Reality 入站
5. 下载 geoip/geosite 路由数据
6. 开启 BBR 加速
7. 输出客户端连接信息 + 分享链接

---

## 连接参数

部署完成后信息保存在 `reality_node_info.txt`：

| 参数 | 值 |
|------|-----|
| 协议 | VLESS |
| 地址 | (服务器 IP) |
| 端口 | 8443 |
| UUID | (自动生成) |
| Flow | xtls-rprx-vision |
| 传输 | tcp |
| 安全 | reality |
| SNI | www.microsoft.com |
| Fingerprint | chrome |

---

## 客户端

- **v2rayN (Windows)**: 添加 VLESS → Reality
- **Shadowrocket (iOS)**: VLESS + Reality
- **v2rayNG (Android)**: VLESS + Reality
- **sing-box**: 支持 VLESS Reality 出站

---

## 服务管理

```bash
systemctl status xray
systemctl restart xray
journalctl -u xray -f

# 卸载
systemctl stop xray && systemctl disable xray
rm -rf /usr/local/bin/xray /usr/local/etc/xray /var/log/xray
rm -f /etc/systemd/system/xray.service /usr/local/bin/*.dat
systemctl daemon-reload
```

---

**最后更新**: 2026-06-22
