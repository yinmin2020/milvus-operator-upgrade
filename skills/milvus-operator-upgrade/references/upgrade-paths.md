# Milvus Operator 升级路径策略（官方文档为准）

本 skill 的版本路径以 **官方文档** 为准，**不跟随 webinar**（不强制经 2.6.24）。机器可读配置见 `scripts/upgrade_paths.json`，逻辑见 `scripts/upgrade_paths.py`。

## 文档入口

| 场景 | 文档 |
|------|------|
| Cluster 2.5 → 2.6 | https://milvus.io/docs/v2.6.x/upgrade_milvus_cluster-operator.md |
| Standalone 2.5 → 2.6 | https://milvus.io/docs/v2.6.x/upgrade_milvus_standalone-operator.md |
| Cluster 2.6 → 3.0 | https://milvus.io/docs/upgrade_milvus_cluster-operator.md |
| Standalone 2.6 → 3.0 | https://milvus.io/docs/upgrade_milvus_standalone-operator.md |
| 博客（2.5→2.6 补充） | https://milvus.io/blog/how-to-safely-upgrade-from-milvu-2-5-x-to-milvus-2-6-x.md |

## 两端对等终点

用户可选任一合法**最终**目标（选项框只列终点，选后再展开 hops）：

- **(A)** 停在用户选定的 GA **2.6.y**（例如 2.5→2.6.10，或 2.6.10→2.6.20）
- **(B)** 升到 GA **3.0.y**（例如 3.0.3）

不是每个用户都必须去 3.0。

## 可选版本清单（全部 GA）

`upgrade_paths.json` 的 `ga_2_6` / `ga_3_0` 列出**全部** GA 版本，选项 = 其中严格高于源版本的所有 tag：

| 系列 | GA 版本 | 来源 |
|------|---------|------|
| 2.6 | v2.6.0 … v2.6.26（27 个） | milvus-docs `v2.6.x` release_notes.md 列到 v2.6.25；GitHub Releases（prerelease=false）另有 v2.6.26（2026-10-26 发布） |
| 3.0 | v3.0.0 … v3.0.4（5 个） | milvus-docs `v3.0.x` release_notes.md 列到 v3.0.3；GitHub Releases 另有 v3.0.4（2026-10-26 发布） |
| 排除 | v2.6.0-rc1、v3.0-beta | 预发布，不作为目标 |

核对日期 2026-10-29（milvus.io 对抓取返回 403，故以 milvus-io/milvus-docs 源文件和 GitHub Releases 为准）。新补丁发布后：追加到 `ga_*`、更新 `latest_known_*`；`recommended_*` 只在文档验证后再改。

- 排序：推荐项在前（2.6 推荐、3.0 推荐），其余从新到旧。
- 展示：先选终态（2.6 / 3.0），再在该系列里分页选具体版本，允许直接输入 tag（见 SKILL.md 第 C 节）。

## 镜像仓库可用性（`scripts/registry_check.py`）

候选终点和选定目标的**每一跳**镜像都按用户当前镜像的仓库（如 `registry.cn-hangzhou.aliyuncs.com/xy-zy/milvus`，默认 `milvusdb/milvus`）做只读检查：

1. registry v2 `HEAD /v2/<repo>/manifests/<tag>`（401 Bearer → 匿名 token → 重试）：200 = present，404 = absent。
2. API 无法确定时兜底：`docker manifest inspect` / `skopeo inspect --raw`（远端 manifest），`crictl inspecti` / `ctr images ls`（本地缓存，只能证明存在）。
3. 仍无法确定（网络不通、私有仓库 401/403、429/5xx）= unverified：预检 WARN，不 FAIL。

| 结果 | 选项 | 选定目标 |
|------|------|----------|
| present | `TARGET_OPTION pull=present` | `target_image_pull PASS` |
| unverified | `TARGET_OPTION pull=unverified`（可选，需提示） | `target_image_pull WARN` |
| absent（任一跳） | `TARGET_UNAVAILABLE`（不可选） | `target_image_pull FAIL`（rc=5，未做改动） |

钉选的推荐 tag 在仓库中不存在时，推荐改为该系列仓库里存在的最新版。不拉镜像、不读凭据；`MILVUS_REGISTRY_CHECK=0` 关闭检查。

## 硬规则

| 规则 | 行为 |
|------|------|
| 源 `<2.5.16` | 路径中先 hop 到 `≥2.5.16`（Cluster 同时启用 mixCoord） |
| 源 `2.6.0-rc*` | **BLOCKED**（官方声明与正式版不兼容） |
| 目标 beta/rc/alpha（含 `v3.0-beta` / `3.0.0-beta`） | **BLOCKED**，引用文档 |
| 2.5 不能直达 3.0 | 经 2.6.x 桥接后再到 3.0 |
| 目标 ≤ 源 | **BLOCKED**（不支持降级/同版本） |
| 2.5→2.6 | 必须先有 **operator ≥ 1.3.7**；Cluster 在改 Milvus 镜像前启用 **mixCoord**。本 skill **不跨 NS 升级 operator**，不足则预检 FAIL，由用户用原安装方式升级 operator 后重跑 |
| 2.6.x → GA 3.0.y | 官方：任意 2.6.x 可到 3.0；**已验证**路径 2.6.20→3.0.3。若源 2.6.x `<2.6.20`：**软警告**（不阻断），建议非生产先验证。**不强制** hop 经 2.6.24 |
| Cluster → 3.0 | 文档倾向**完整 CR apply**（显式 `indexNode.replicas: 0`），不要只用缺字段的 image-only merge；本 skill 在现有 CR 上改写后 apply，并警告组件与官方模板差异 |

## 源版本发现顺序

1. CR `spec.components.image`
2. CR `status.currentImage`
3. Milvus Pod 容器镜像

解析支持非纯 `x.y.z`（rc/beta/alpha、`v3.0-beta`、spoken `3.0.0-beta`）。

## 执行约定

- 选项框只列**合法终点**（且镜像在仓库里存在或无法确认）；选定后 `plan` 展开所需 hops，并检查每一跳镜像。
- 每 hop 之间等待 **Healthy + MilvusUpdated + 镜像一致**。
- 升级仍主要只改 Milvus 镜像（+ root `securityContext`）；例外仅文档要求的 operator 门槛提示与 Cluster `mixCoord` / 3.0 Cluster 完整 CR。
- 密钥只来自环境变量；决策走选项框；不捆绑二进制；NS 作用域。

## 钉选版本（`upgrade_paths.json` pins）

见 JSON：`ga_2_6`、`ga_3_0`（全部 GA 清单）、`bridge_2_5_with_mixcoord`、`recommended_2_6`、`recommended_3_0`、`verified_2_6_to_3_0_source/target`、`min_operator_for_2_5_to_2_6` 等。更新产品钉选时改 JSON 并跑 `python3 scripts/upgrade_paths.py selftest` 与 `python3 scripts/registry_check.py selftest`。
