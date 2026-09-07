# journald —— 系统日志占用上限

systemd 的日志默认可以涨到磁盘容量的 10%。小盘机器上这足够把根分区写满，而根分区
写满的表现是各种服务莫名其妙失败 —— 现象和原因看起来毫不相关，很难联想到磁盘。

## 1. 前置检查（只读）

```bash
journalctl --disk-usage
"$SKILL/scripts/hao-guard.sh" managed-file /etc/systemd/journald.conf.d/hao.conf
```

返回 `foreign` → 拒绝覆盖，把路径报给用户。

## 2. 写 drop-in

`templates/journald.conf` → `/etc/systemd/journald.conf.d/hao.conf`，然后：

```bash
systemctl restart systemd-journald
```

用 drop-in 而不是改 `/etc/systemd/journald.conf` 主文件：主文件属于 systemd 包，
改了它以后每次升级 apt 都会来问冲突怎么办，而 drop-in 目录本来就是为覆盖准备的。

## 3. 验证

```bash
journalctl --disk-usage
systemd-analyze cat-config systemd/journald.conf | grep -E 'SystemMaxUse|MaxRetentionSec'
```

第二条回读的是 systemd 合并之后的最终配置，比 `cat` 我们自己写的文件有意义 ——
如果有别的 drop-in 排在后面把我们的值覆盖了，只有这里看得出来。

## 4. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record journald installed \
    managed:/etc/systemd/journald.conf.d/hao.conf
"$SKILL/scripts/hao-state.sh" intent journald \
    system_max_use="$(sed -n 's/^SystemMaxUse=//p' /etc/systemd/journald.conf.d/hao.conf)"
"$SKILL/scripts/hao-state.sh" handoff
```

## 常见问题

- **`journalctl --disk-usage` 还是很大**：上限只约束将来的写入，已经存在的日志
  不会自动删掉。要立刻回收空间用 `journalctl --vacuum-size=500M`——这会删除旧
  日志，**执行前告诉用户**，正在排查问题的机器上旧日志可能正是他要的东西。
- **改完没生效**：`/etc/systemd/journald.conf.d/` 下按文件名排序，排在 `hao.conf`
  后面的 drop-in 会覆盖我们的值。用上面第二条命令确认最终值。
