# 卸载

**不要主动做这件事。** 卸载是破坏性的，只有用户明确要求某个具体的卸载操作时
才执行，而且要先讲清会删掉什么、什么会被一起带走。

HAO 没有"一键卸载全部"，也不该有。

## 通用前置：先看清要删什么

```bash
"$SKILL/scripts/hao-state.sh" services
"$SKILL/scripts/hao-state.sh" credentials
cat /var/lib/hao/manifest.json
```

把清单里对应服务的资源路径念给用户听，确认哪些要删、哪些要留。
`shared` 和 `observed` 的资源**不要删**——它们不属于 HAO。

## Docker Compose 类服务

```bash
cd /opt/docker-services/<service>
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
rm -rf /opt/docker-services/<service>          # 里面可能有含密钥的配置文件
rm -f /etc/nginx/conf.d/hao-<service>.conf /etc/nginx/hao-<service>-body.conf
nginx -t && systemctl reload nginx             # 先测试再重载
```

## site 站点

```bash
systemctl disable --now "hao-site-<id>.service"   # 仅 node 类型
rm -f /etc/systemd/system/hao-site-<id>.service
systemctl daemon-reload
rm -f /etc/nginx/conf.d/hao-site-<id>.conf /etc/nginx/hao-site-<id>-body.conf
rm -f /usr/local/bin/hao-site-update-<id>
nginx -t && systemctl reload nginx
```

`/opt/hao-sites/<id>`（代码）和 `/var/www/hao-sites/<id>`（发布产物）
**要单独问**：代码目录可能有用户没推上去的改动。

站点的状态记录在 `site-<id>` 下（每个站点一条），不是统一的 `site`。

## 基础模块（手工反向操作）

- **nginx**：`systemctl disable --now nginx`，再删掉不要的
  `/etc/nginx/conf.d/*.conf`（HAO 写的文件开头有 `# Managed by HAO`，
  用 `hao-guard.sh managed-file` 判断）。删主配置前想清楚：其他站点也靠它。
- **docker**：`systemctl disable --now docker` 并按需卸包。
  **注意**：这会影响这台机器上所有容器，不只是 HAO 部署的。
- **maintenance**：删 `/etc/fail2ban/jail.d/hao-sshd.local`、
  `/etc/systemd/journald.conf.d/hao.conf`、`/etc/sysctl.d/99-hao-swap.conf`。
  `daemon.json` 和 `fstab` 是 `shared`，只能改回我们加的那部分，
  **不要整体删**。swap 要先 `swapoff` 再删文件和 fstab 行。
- **node / uv / claude-code**：卸包或删二进制。写进 AI 助手指令文件的约定块
  用标记包裹（`HAO-UV` / `HAO-GIT-GITHUB` / `HAO-HANDOFF`），
  手工删掉 BEGIN 到 END 之间连同标记本身，块外内容不要动。

## 清理 HAO 状态

**只在对应服务真的已经删掉之后**再清状态：

```bash
rm -f /var/lib/hao/services/<service>.json /var/lib/hao/services/<service>.resources
"$SKILL/scripts/hao-state.sh" handoff        # 重建 manifest 与交接文档
```

`handoff` 会同时重建 `manifest.json`，所以删完 `services/` 下的文件必须跑一次，
否则清单里会留下一个已经不存在的服务。站点的文件名是 `site-<id>.*`。

状态和现实不一致的两种后果都很烦：
清单里留着已删的服务 → `drift` 一直报缺失；
服务还在却删了清单 → 下一个 agent 会把它当成无主资源，可能拒绝操作或误覆盖。

整台机器要销毁就不用清了，直接销毁。但**销毁前提醒用户导出他要留的东西**：
凭据文件、数据库数据、代码里没推的改动。
