# swap —— 内存不够时的兜底

小内存 VPS（1~2 GB）跑构建或数据库很容易 OOM，进程被内核直接杀掉，日志里往往
只留一行。swap 让机器变慢而不是变死。

## 1. 前置检查（只读）

```bash
swapon --show                    # 有活动 swap 就别碰
awk '/MemTotal/ {print int(($2 + 1023) / 1024)}' /proc/meminfo
"$SKILL/scripts/hao-guard.sh" managed-file /etc/sysctl.d/99-hao-swap.conf
```

**已有活动 swap 就跳过**，把现状报给用户。再加一个 swap 文件不会让机器更稳，
只是多占磁盘。sysctl 文件返回 `foreign` → 拒绝覆盖。

## 2. 决定大小

| 物理内存 | swap 大小 |
|---|---|
| ≤ 2048 MB | 2048 MB |
| ≤ 4096 MB | 4096 MB |
| > 4096 MB | **问用户**要不要，默认不建 |

内存超过 4 GB 还 OOM，通常是程序本身有问题。这时加 swap 只会把故障从「被杀掉」
变成「慢到不可用」，后者更难排查。

## 3. 创建

```bash
SWAP=/swapfile
# /swapfile 已存在但不是 swap 文件 → 换个名字，不要覆盖
[ -e "$SWAP" ] && ! file "$SWAP" | grep -qi swap && SWAP=/swapfile.hao

fallocate -l "${SIZE_MB}M" "$SWAP" || dd if=/dev/zero of="$SWAP" bs=1M count="$SIZE_MB" status=none
chmod 600 "$SWAP"          # 必须 600：swap 里可能有内存中的敏感数据
mkswap "$SWAP" >/dev/null
swapon "$SWAP"

# 持久化（先查重，别重复追加）
grep -qsE "^[[:space:]]*${SWAP}[[:space:]]+" /etc/fstab \
    || echo "$SWAP none swap sw 0 0" >> /etc/fstab
```

`fallocate` 失败退回 `dd` 不是多余的：某些文件系统上 `fallocate` 生成的文件带
空洞，`mkswap` 会拒绝它。

然后写 `templates/swap-sysctl.conf` → `/etc/sysctl.d/99-hao-swap.conf`，
再 `sysctl -p /etc/sysctl.d/99-hao-swap.conf`。

## 4. 验证

```bash
swapon --show                    # 必须能看到刚建的那一行
sysctl -n vm.swappiness          # 应当是 10
```

回读实际生效值，不要因为文件写成功就报成功。

## 5. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record swap installed \
    managed:/etc/sysctl.d/99-hao-swap.conf \
    shared:/etc/fstab
"$SKILL/scripts/hao-state.sh" handoff
```

`/etc/fstab` 记 `shared` 而不是 `managed`：我们只往里加了一行，下一个 agent
不能整体重写它。

**swap 文件本身不进记录。** `drift` 会对记录里的每个路径算 sha256，几 GB 的
swap 文件既算不动、内容也时刻在变 —— 记进去等于让 `drift` 永久报漂移。

## 常见问题

- **重启后 swap 没了**：`/etc/fstab` 那行没写进去，或者写的路径和实际文件不一致
  （用了 `/swapfile.hao` 兜底时容易对不上）。`swapon --show` 加 `grep swap /etc/fstab`
  一起看。
- **`swapon` 报 `insecure permissions`**：`chmod 600` 漏了。
