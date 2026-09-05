# node —— 系统级 Node.js 运行时

从 NodeSource 官方 apt 仓库**系统级**安装，让 `node`/`npm` 落在 `/usr/bin`。

## 为什么必须是系统级

真实事故：某项目的 systemd 单元写死 `/usr/bin/node`，而机器上的 Node 装在某个
用户 home 下的 nvm 里 → 服务永远起不来。装在用户目录的 Node 对
**systemd 服务、其他用户、非登录 shell** 都不可见。

所以：本模块只认 `/usr/bin/node`。PATH 里有 nvm 的 node **不算已安装**，
但也**不要删除它**——那是用户自己的开发环境。发现了只提示一句。

## 1. 检查

```bash
PATH_NODE="$(command -v node 2>/dev/null || true)"
[ -n "$PATH_NODE" ] && [ "$PATH_NODE" != /usr/bin/node ] \
    && echo "注意：PATH 里的 node 不在系统路径（$PATH_NODE），本模块只保证 /usr/bin/node"

# 系统 node 的主版本
[ -x /usr/bin/node ] && /usr/bin/node --version
[ -x /usr/bin/npm ] && /usr/bin/npm --version
```

判断规则（默认目标主版本 22 LTS）：

| 现状 | 动作 |
|---|---|
| `/usr/bin/node` 主版本 == 目标，且 `/usr/bin/npm` 存在 | **干净跳过**，只验证。不要碰 apt |
| 主版本一致但缺 npm | 重装 `nodejs` 包 |
| 主版本不一致 | 安装目标版本 |
| 没有 `/usr/bin/node` | 安装 |
| 用户明确要求刷新到最新小版本 | 重新装一遍 |

## 2. 安装

```bash
export DEBIAN_FRONTEND=noninteractive
NODE_MAJOR=22          # 用户可指定其他主版本，必须是纯数字

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d

# GPG key：已存在就复用（要刷新就先删掉那个文件）
if [ ! -e /etc/apt/keyrings/nodesource.gpg ]; then
    curl -fsSL --connect-timeout 30 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --batch --dearmor > /tmp/nodesource.gpg
    [ -s /tmp/nodesource.gpg ] || { echo "GPG key 为空，中止"; exit 1; }
    install -m 0644 /tmp/nodesource.gpg /etc/apt/keyrings/nodesource.gpg
fi

printf '# Managed by HAO\n# Service: node\ndeb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
    "$NODE_MAJOR" > /etc/apt/sources.list.d/nodesource.list

apt-get update -qq
apt-get install -y nodejs
```

写 apt 源前先比对：内容一致就别动文件（少一次无谓的 apt 元数据刷新）；
不一致先备份再覆盖。

## 3. 验证（四项都要过）

```bash
/usr/bin/node --version        # 主版本必须等于目标
[ -x /usr/bin/npm ] && /usr/bin/npm --version
command -v node                # 必须在 PATH 里
command -v npm
```

主版本不符或 `/usr/bin/npm` 不存在就是**失败**，停下来报告，不要继续。

## 4. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record node installed \
    managed:/etc/apt/sources.list.d/nodesource.list \
    managed:/etc/apt/keyrings/nodesource.gpg \
    observed:/usr/bin/node
"$SKILL/scripts/hao-state.sh" handoff
```

`/usr/bin/node` 记 `observed`：它由 apt 包管理，升级会变，记 managed 会误报漂移。

## 常见问题

- **systemd 服务报 `/usr/bin/node: no such file`**：只装了 nvm 版本。跑这个模块。
- **`npm -g` 装的命令找不到**：全局 bin 在 `/usr/lib/node_modules/.bin` 或
  `/usr/bin`，确认 PATH；非登录 shell 的 PATH 可能更窄。
- **apt 里已有发行版 `nodejs` 包冲突**：NodeSource 源优先级更高即可覆盖；
  仍冲突就先 `apt-get remove nodejs libnode-dev` 再装（要先问用户，
  这会动到已有环境）。
