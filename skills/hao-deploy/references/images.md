# 镜像固定 tag

容器镜像**默认不用 `latest`**。用 `latest` 意味着同一份部署过程在两周后
可能装出完全不同的东西——对"即用即抛、随时重放"的机器来说，这是最容易
踩到的坑：新机器上重放一遍，行为却和旧机器不一样。

## 当前评审过的候选

评审日期 **2026-07-13**（UTC）。

| 服务 | 默认（固定 tag） | 备选 1 | 备选 2 | 上游成熟度 |
|---|---|---|---|---|
| cliproxyapi | `eceasy/cli-proxy-api:v7.2.71` | `eceasy/cli-proxy-api:latest` | `eceasy/cli-proxy-api:v7.2.70` | stable |
| new-api | `calciumion/new-api:v1.0.0-rc.21` | `calciumion/new-api:latest` | `calciumion/new-api:v1.0.0-rc.20` | release-candidate |

`latest` 是**明示的可选项**，不是默认。用户要用就用，但要告诉他代价：
下次重放不保证一致。

new-api 上游还在 release-candidate 阶段——这一点要如实告诉用户，
别让他以为是稳定版。

## 部署前先确认 tag 还在

上游可能删 tag 或改动 registry：

```bash
docker manifest inspect eceasy/cli-proxy-api:v7.2.71 >/dev/null && echo "tag 存在"
```

拉不到就停下来，把情况告诉用户，让他选备选 tag 或 `latest`，不要默默换一个。

## 表过期了怎么办

上面的日期距今很久（比如超过几个月）时，**如实告诉用户这份固定 tag 已经旧了**，
并给出选择：

1. 继续用固定 tag —— 可重放，但拿不到新版本的修复；
2. 改用 `latest` —— 拿到最新，但放弃可重放性；
3. 让用户自己去上游 releases 页面挑一个当前的固定 tag（推荐）。

不要自己去猜一个"应该存在"的新版本号，那很可能拉不到。
