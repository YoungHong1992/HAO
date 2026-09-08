# 卸载

**不要主动做这件事。** 卸载是破坏性的，只有用户明确要求某个具体的卸载操作时
才执行，而且要先讲清会删掉什么、什么会被一起带走。

HAO 没有"一键卸载全部"，也不该有。

## 通用前置：先看清要删什么

```bash
"$SKILL/scripts/hao-state.sh" services
"$SKILL/scripts/hao-state.sh" credentials
"$SKILL/scripts/hao-state.sh" orphans        # HAO 写过却没记录的文件，删之前一起看
cat /var/lib/hao/manifest.json
```

`orphans` 在这里不是可选项：清单里没有的文件，删服务时不会被带走，会留在
`/etc/nginx`、`/usr/local/bin` 这些目录里变成无主残留。

把清单里对应服务的资源路径念给用户听，确认哪些要删、哪些要留。
`shared` 和 `observed` 的资源**不要删**——它们不属于 HAO。

## Docker Compose 类服务

```bash
cd /opt/<service>
docker compose ps                 # 先看当前状态
docker compose down               # 停止并移除容器（不动 volume）
```

**volume 是数据所在。** `docker compose down -v` 会删掉数据库这类 named volume，
数据不可恢复。执行前：

1. 明确告诉用户"这一步会删掉数据库数据"；
2. 主动提议先备份：
   ```bash
   mkdir -p "/backup/<service>-$(date +%Y%m%d_%H%M%S)"
   docker run --rm -v <volume>:/data -v /backup/<dir>:/backup \
       alpine tar czf /backup/data.tar.gz -C /data .
   ```
3. 得到明确确认后才加 `-v`。

然后按需删除服务目录与 Nginx 配置：

```bash
rm -rf /opt/<service>                          # 里面可能有含密钥的配置文件
rm -f /etc/nginx/conf.d/<域名>.conf /etc/nginx/snippets/<域名>.conf
nginx -t && systemctl reload nginx             # 先测试再重载
```

## site 站点

`CONF_NAME` = 有域名时是域名，无域名时是站点 ID（和部署时一致）。

```bash
systemctl disable --now "<id>.service"            # 仅 node 类型
rm -f /etc/systemd/system/<id>.service
systemctl daemon-reload
rm -f /etc/nginx/conf.d/<CONF_NAME>.conf /etc/nginx/snippets/<CONF_NAME>.conf
rm -f /usr/local/bin/<id>-update
nginx -t && systemctl reload nginx
```

`/opt/<id>`（代码）和 `/var/www/<域名>`（发布产物）**要单独问**：代码目录可能有
用户没推上去的改动，而 `/var/www/<域名>` 是通用路径，里面可能混有用户自己放的东西。

**证书不要顺手删。** `/etc/letsencrypt/live/<域名>/` 归 certbot 管，别的服务
可能还在用同一张证书。真要停止续期就用 certbot 自己的命令：

```bash
certbot certificates                  # 先看有哪些
certbot delete --cert-name <域名>     # 确认后再删
```

站点的状态记录在 `site-<id>` 下（每个站点一条），不是统一的 `site`。

## 基础模块（手工反向操作）

- **nginx**：`systemctl disable --now nginx`，再删掉不要的
  （调优 drop-in 是 `/etc/sysctl.d/99-hao-nginx.conf` 和
  `/etc/security/limits.d/90-hao-nofile.conf`，删了要重启才恢复默认值）
  `/etc/nginx/conf.d/*.conf`（HAO 写的文件开头有 `# Managed by HAO`，
  用 `hao-guard.sh managed-file` 判断）。删主配置前想清楚：其他站点也靠它。
  还有两个容易漏的：共享片段
  `/etc/nginx/snippets/{ssl-hardening,acme-challenge,redirect-to-https}.conf`
  和证书续期钩子 `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`
  （钩子是 nginx 模块装的；删了它以后证书续期后不会重载 Nginx，
  站点会在续期后继续用旧证书直到下次重启）。
  同目录下的 `scanner-blocks.conf` / `security-headers.conf` **不属于本模块**，
  是 `nginx-hardening` 的，见下一条。
  安装时如果把包自带的 `conf.d/default.conf` 改名成了 `.disabled`，
  要不要改回来问用户 —— 那是 nginx 包的欢迎页，多数人并不想要它回来。
- **nginx-hardening**：顺序有讲究，**先改引用、再删被引用的文件**。
  ```bash
  # 1. 先从每个站点的内容块里删掉那两行 glob include，以及（如果加过）
  #    整段后台 Basic Auth 网关 location —— auth_basic_user_file 还指着
  #    htpasswd 时就把 htpasswd 删了，后台每个请求都是 500。
  grep -rln 'scanner-blocks\*\.conf\|htpasswd-' /etc/nginx/snippets/
  # 2. 编辑上面列出的文件，删掉那些行/那一段
  nginx -t && systemctl reload nginx
  # 3. 确认没有引用了，再删本模块的文件
  rm -f /etc/nginx/conf.d/00-hao-hardening.conf \
        /etc/nginx/snippets/scanner-blocks.conf \
        /etc/nginx/snippets/security-headers.conf
  rm -f /etc/nginx/.htpasswd-<CONF_NAME>          # 后台口令，装过网关才有
  rm -f /etc/hao/nginx-hardening.env              # 同上，凭据文件
  nginx -t && systemctl reload nginx
  ```
  被改过内容块的每个站点都要**重跑它自己的 record**（清单从
  `/var/lib/hao/services/site-<ID>.resources` 读，别凭记忆敲），否则 drift
  会一直报这些站点的哈希不对。
  删完要如实告诉用户：扫站拦截、限流、安全响应头都没了。
- **fail2ban-nginx**：删 jail 之后**必须 reload**，否则 fail2ban 继续按内存里
  的配置封人，而机器上已经找不到这套规则的来源了。
  ```bash
  fail2ban-client status hao-nginx-scan   # 先看看有没有还在封着的 IP
  rm -f /etc/fail2ban/jail.d/hao-nginx.local \
        /etc/fail2ban/filter.d/hao-nginx-scan.conf
  fail2ban-client reload                  # 不做这一步等于没删
  fail2ban-client status | grep -c hao-nginx || echo "两个 jail 都没了"
  ```
  `/etc/fail2ban/filter.d/nginx-http-auth.conf` 是 fail2ban 包自带的，
  auth jail 只是引用它，**不要删**。sshd jail（`hao-sshd.local`）属于
  `fail2ban` 模块，是另一条。
- **docker**：`systemctl disable --now docker` 并按需卸包。
  **注意**：这会影响这台机器上所有容器，不只是 HAO 部署的。日志轮转那部分是
  `daemon.json` 里的 `log-driver` / `log-opts` 两个键，`shared` 资源，
  只能改回这两个键，**不要整体删**这个文件。
- **fail2ban**：删 `/etc/fail2ban/jail.d/hao-sshd.local`，然后
  `systemctl restart fail2ban`（还想留着 fail2ban）或 `systemctl disable --now fail2ban`
  并卸包。删掉之后 SSH 就没有防爆破了，说清这一点。
- **swap**：顺序是 `swapoff` → **先删 `/etc/fstab` 里那一行** → 最后删文件。
  ```bash
  swapoff /swapfile                      # 或 /swapfile.hao，按记录里的实际路径
  # 编辑 /etc/fstab，删掉那一行（fstab 是 shared，只删我们加的那行）
  rm -f /swapfile
  rm -f /etc/sysctl.d/99-hao-swap.conf
  ```
  **不能反过来先删文件**：`/etc/fstab` 里留着一条指向已经不存在的文件的 swap 行，
  systemd 生成的 swap 单元会启动失败，机器可能开机进 emergency shell。
  （删一个正在使用的 swap 文件本身并不会让机器起不来——inode 会被 swapon 持有到
  swapoff 为止。以前这里的因果写反了。）新版本写 fstab 时会带 `nofail`，
  但老机器上那行可能没有。
  内存吃紧的机器上关掉 swap 会让 OOM 回来，先问清楚。
- **journald**：删 `/etc/systemd/journald.conf.d/hao.conf`，
  `systemctl restart systemd-journald`。上限没了之后日志会重新按磁盘 10% 增长。
- **git**：卸包或保留都行。`~/.gitconfig` 是 `shared`——只删我们写的
  `user.name` / `user.email`（`git config --global --unset`），**不要删整个文件**。
- **gh**：删 `/usr/local/bin/github-authorize`、
  `/etc/apt/sources.list.d/github-cli.list`、
  `/etc/apt/keyrings/githubcli-archive-keyring.gpg`，按需 `apt-get remove gh`。
  用户的 gh 登录凭据在他自己的 `~/.config/gh/` 下，要不要清由他决定；
  真要撤销授权得让他自己去 GitHub 的 Settings → Applications 里撤。
- **node / uv / claude-code**：卸包或删二进制。
- 写进 AI 助手指令文件的约定块用标记包裹（`HAO-UV` / `HAO-GH` / `HAO-HANDOFF`），
  手工删掉 BEGIN 到 END 之间连同标记本身，
  块外内容不要动。BEGIN 行的原文形如
  `<!-- HAO-UV BEGIN (managed by HAO, do not edit inside) -->`，END 行是
  `<!-- HAO-UV END -->` —— 按原文去搜，别按简写搜（见 `references/handoff.md`）。

## 清理 HAO 状态

**只在对应服务真的已经删掉之后**再清状态：

```bash
rm -f /var/lib/hao/services/<service>.json \
      /var/lib/hao/services/<service>.resources \
      /var/lib/hao/services/<service>.intent
"$SKILL/scripts/hao-state.sh" handoff        # 重建 manifest、意图文档与交接文档
```

`handoff` 会同时重建 `manifest.json` 和 `DEPLOY-INTENT.md`，所以删完 `services/`
下的文件必须跑一次,否则清单里会留下一个已经不存在的服务。站点的文件名是
`site-<id>.*`。

删意图之前先问一句：**用户是不是还想留着那份重建依据。** 服务删了但意图还有用的
情况很常见（换机器重建）。真要删就先让他把 `DEPLOY-INTENT.md` 存走。

状态和现实不一致的两种后果都很烦：
清单里留着已删的服务 → `drift` 一直报缺失；
服务还在却删了清单 → 下一个 agent 会把它当成无主资源，可能拒绝操作或误覆盖。

整台机器要销毁就不用清了，直接销毁。但**销毁前提醒用户导出他要留的东西**：
`/var/lib/hao/DEPLOY-INTENT.md`（重建依据）、凭据文件、数据库数据、
代码里没推的改动。
