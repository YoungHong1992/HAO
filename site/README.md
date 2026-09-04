# site —— 从 Git 仓库部署自有站点（静态 / Node）

通用的「部署我自己的项目」组件：一个 profile 声明若干站点，模块完成 克隆 → 构建 → 发布/启动 → Nginx 虚拟主机 → 证书 → 更新脚本 的全部流程。适合 Docusaurus/VitePress/Hugo 等静态站点，以及自带 `server.js` 的 Node 应用。

## 多站点模型

`HAO_SITES` 声明逗号分隔的站点 ID（小写字母、数字、连字符，如 `blog-v2`）。每个站点读取一组 `HAO_SITE_<ID>_*` 变量——ID 转为大写、连字符转为下划线后作为前缀（`blog-v2` → `HAO_SITE_BLOG_V2_*`），符合 profile 的 `^HAO_[A-Z0-9_]+$` 变量名约束。

一次运行可部署多个站点；域名与端口在站点间自动查重。

## 用法

```bash
# 直接运行（本模块的全部配置均通过环境变量传入，无交互式确认）
sudo HAO_SITES="blog,tools" \
  HAO_SITE_BLOG_REPO="git@github.com:me/blog.git" \
  HAO_SITE_BLOG_TYPE="static" \
  HAO_SITE_BLOG_DOMAIN="blog.example.com" \
  HAO_SITE_BLOG_BUILD="npm ci && npm run build" \
  HAO_SITE_BLOG_OUTPUT="build" \
  HAO_SITE_TOOLS_REPO="https://github.com/me/tools.git" \
  HAO_SITE_TOOLS_TYPE="node" \
  HAO_SITE_TOOLS_DOMAIN="tools.example.com" \
  ./install.sh
```

亦可把上述变量写入 profile 文件后通过 `hao apply --profile ...` 编排（根 CLI 注册后可用 `--services site`）。模块依赖 Nginx 与 Git；node 类型站点还需要 Node.js（将 `node` 加入 `HAO_SERVICES` 或自行安装）。

## 配置变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `HAO_SITES` | 是 | — | 逗号分隔的站点 ID 列表 |
| `HAO_SITE_<ID>_REPO` | 是 | — | Git 仓库地址（ssh/https）或本地路径 / `file://`（本地路径便于测试） |
| `HAO_SITE_<ID>_TYPE` | 是 | — | `static`（静态站点）或 `node`（Node 应用） |
| `HAO_SITE_<ID>_DOMAIN` | 否 | 空 | 域名。留空 = 80 端口默认站点（`server_name _`），不申请证书；同一批站点中仅允许一个留空 |
| `HAO_SITE_<ID>_BRANCH` | 否 | `main` | 部署分支 |
| `HAO_SITE_<ID>_BUILD` | 否 | 空 | static：构建命令，在克隆目录内以目标用户执行（env `CI=true`） |
| `HAO_SITE_<ID>_OUTPUT` | 否 | 见说明 | static：产物目录（相对克隆目录）。设置了 `BUILD` 时默认 `build`；未设置 `BUILD` 时默认 `.`（发布仓库根目录，自动排除 `.git`） |
| `HAO_SITE_<ID>_START` | 否 | `server.js` | node：入口文件（相对克隆目录，或绝对路径） |
| `HAO_SITE_<ID>_PORT` | 否 | 自动 | node：监听端口。留空时从 8100 起自动分配（避开已占用端口）；幂等重跑时复用既有 systemd 单元中的端口，不会漂移 |
| `HAO_SITE_<ID>_TARGET_USER` | 否 | `$SUDO_USER`，否则 `root` | 克隆/构建/运行的系统用户（必须已存在） |
| `HAO_SITE_<ID>_CERT` | 否 | `yes` | 设置 `DOMAIN` 时申请 Let's Encrypt 证书（acme.sh webroot，ECC-256，失败自动降级自签名） |
| `HAO_SITE_<ID>_REDIRECT` | 否 | `yes` | 80→443 跳转开关，详见下节 |
| `HAO_SITE_<ID>_ENV` | 否 | 空 | node：额外 `Environment=` 条目，格式 `KEY=VALUE,KEY2=VALUE2`（值不支持逗号；端口请用 `HAO_SITE_<ID>_PORT`，不要在 ENV 中设置 `PORT`） |

仅对单一类型生效的变量（如 static 站点设置 `PORT`、node 站点设置 `BUILD`）会被忽略并给出告警。

## 证书与 HTTP→HTTPS 跳转（重要）

真实教训：某次部署自动开启了 HTTP→HTTPS 跳转，但云安全组未放行 443/TCP，整站直接不可访问（522 超时）。因此本模块的跳转策略是**显式可控**的：

- `REDIRECT=yes`（默认）且**真实 Let's Encrypt 证书签发成功**时，80 端口 server 块将 ACME 路径之外的请求 301 到 https，并打印安全组提醒：

  ```
  ⚠️ 请确认云服务器安全组/防火墙已放行 443/TCP，否则跳转后站点将完全不可访问（典型现象: 522 超时）
  ```

- `REDIRECT=no`、未设置 `DOMAIN`、或证书降级为自签名时，80 端口**直接提供站点内容**，不做跳转。
- 自签名证书永不触发跳转；重跑时如果已有自签名证书会重试申请真实证书，已签发的真实证书不重复申请（acme.sh 的 cron 负责到期续期）。

## 生成的文件

| 路径 | 说明 |
|---|---|
| `/opt/hao-sites/<id>` | 仓库克隆（目标用户所有）；已存在时校验 origin 与配置一致后 fetch + reset |
| `/var/www/hao-sites/<id>` | static 发布目录（每次发布先清空再同步） |
| `/etc/systemd/system/hao-site-<id>.service` | node 单元（`# Managed by HAO` 头，`NoNewPrivileges`/`PrivateTmp` 加固，0640 权限） |
| `/etc/nginx/conf.d/hao-site-<id>.conf` | Nginx 虚拟主机（`# Managed by HAO` / `# HAO-SITE: <id>` 头，写入前备份，`nginx -t` 失败自动恢复） |
| `/usr/local/bin/hao-site-update-<id>` | 更新脚本（0755，嵌入解析后的字面量，可独立运行） |

node 单元中 `ExecStart=<node 绝对路径> <START> <PORT>`，并注入 `Environment="NODE_ENV=production"`、`HOME` 与 `PORT`（应用可通过 `process.env.PORT` 或启动参数拿到端口）。

## 更新站点

```bash
sudo hao-site-update-<id>
```

按站点类型执行：拉取 `origin/<branch>` 并 `reset --hard` →（static）重新构建并发布 /（node）重启 systemd 单元并等待端口 → 重载 Nginx。脚本不依赖本仓库，可独立运行。

## 安全说明

- 所有配置校验（变量格式、端口/域名查重、目标用户存在性）在 root 权限检查**之前**执行，配置错误可在非 root 环境快速暴露。
- 拒绝覆盖的情形（报错退出，不做破坏性操作）：
  - `/opt/hao-sites/<id>` 已存在但不是 Git 检出；
  - 目录中的仓库 origin 与配置的 `REPO` 不一致；
  - Nginx 中 `server_name` 已被无 `HAO-SITE` 标记的配置占用（不抢其他服务的域名）；
  - 同一 `server_name` 已被另一个 HAO 站点占用。
- 仓库地址可能内嵌凭据（`https://user:token@...`），日志与报错中一律脱敏显示。
- 本模块不写凭据文件；`ENV` 中的敏感值只进入 0640 权限的 systemd 单元，不打印到日志。

## 幂等性

重复执行安全：代码 `fetch + reset --hard` 到指定分支；静态发布目录清空后重新同步；systemd 单元与 Nginx 配置按当前 profile 原地重写（写入前自动备份）；已签发的真实证书跳过重复申请；自动分配的端口在重跑时复用既有单元中的值。

## 卸载

```bash
sudo rm /usr/local/bin/hao-site-update-<id> /etc/nginx/conf.d/hao-site-<id>.conf
sudo rm -rf /opt/hao-sites/<id> /var/www/hao-sites/<id>
sudo systemctl disable --now hao-site-<id>.service   # node 站点
sudo rm /etc/systemd/system/hao-site-<id>.service && sudo systemctl daemon-reload
sudo systemctl reload nginx
```
