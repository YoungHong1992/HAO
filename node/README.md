# node — Node.js 运行时（系统级安装）

通过 [NodeSource 官方 apt 仓库](https://github.com/nodesource/distributions) 系统级安装 Node.js LTS，使 `node`/`npm` 落在 `/usr/bin` 标准路径，供任意用户、非登录 shell 与 systemd unit 直接使用。

## 背景

真实事故：某项目的 systemd unit 写死 `ExecStart=/usr/bin/node ...`，而机器上的 Node 实际是用 nvm 装在某用户 home 下的——服务启动直接失败。装在用户目录（nvm）或 `/usr/local`（tarball）的 Node 只对交互登录的特定用户可见，对系统服务、其他用户、cron、CI runner 都不可靠。本模块把 Node.js 作为系统 deb 包（`nodejs`）安装到标准路径。

## 用法

```bash
# 单独运行
sudo ./install.sh                # 交互式
sudo ./install.sh --no-prompt    # 非交互式

# 指定主版本 / 显式升级
sudo HAO_NODE_VERSION=22 ./install.sh --no-prompt
sudo HAO_NODE_ACTION=upgrade ./install.sh --no-prompt
```

（根 CLI 注册完成后，亦可通过 `./hao plan/apply --services node` 编排。）

## 配置变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `HAO_NODE_VERSION` | 否 | `22` | Node.js 主版本号（纯数字，如 `22`、`20`）。对应 NodeSource 仓库 `node_<主版本>.x` |
| `HAO_NODE_ACTION` | 否 | `ensure` | `ensure`：`/usr/bin/node` 已存在且主版本一致则干净跳过（不触碰 apt），仅验证；`upgrade`：刷新仓库配置并升级到该主版本的最新小版本 |

## 安装内容 / 管理的文件

- `/etc/apt/keyrings/nodesource.gpg` — NodeSource 仓库 GPG key（0644；已存在则复用，如需刷新可删除后重跑）
- `/etc/apt/sources.list.d/nodesource.list` — apt 源，头部带 `# Managed by HAO` / `# Service: node` 与发布标识；已有不同内容时先备份（`.bak.时间戳`）再覆盖
- apt 包 `nodejs` → `/usr/bin/node`、`/usr/bin/npm`（NodeSource 包自带 npm，无需单独安装）

## 幂等性

- `ensure` 且 `/usr/bin/node` 主版本与 `HAO_NODE_VERSION` 一致、`/usr/bin/npm` 存在：干净 no-op——不执行任何 apt 操作、不改写仓库文件，只做验证。
- 已安装但主版本不一致、或缺少 npm：安装/重装请求的版本。
- `upgrade`：重写仓库配置（内容一致则不动）并 `apt-get install -y nodejs`，刷新到该主版本最新小版本。
- 判定「已安装」只看系统标准路径 `/usr/bin/node`；用户目录或 `/usr/local` 下的 node 只提示、不视为已安装。

## 安全说明

- 本模块不涉及任何 secret。
- 不卸载、不改动任何用户级 Node 安装（nvm/tarball 原样保留，只是系统多一份标准路径安装；若 `PATH` 中 `/usr/local/bin` 优先于 `/usr/bin`，交互 shell 里命中的可能仍是用户级 node，脚本会给出提示）。
- 覆盖已有 `nodesource.list` 前自动备份。
- 仓库 GPG key 经 HTTPS 下载并 dearmor；apt 全程对包做签名校验。
- 不使用 `curl | bash` 执行 NodeSource setup 脚本，而是手动写入等效的仓库配置——内容可审计、幂等、可带 HAO 管理头。

## 卸载

```bash
sudo apt-get purge nodejs
sudo rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/keyrings/nodesource.gpg
sudo apt-get update
```
