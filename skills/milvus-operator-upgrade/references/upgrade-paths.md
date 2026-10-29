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

- 选项框只列**合法终点**；选定后 `plan` 展开所需 hops。
- 每 hop 之间等待 **Healthy + MilvusUpdated + 镜像一致**。
- 升级仍主要只改 Milvus 镜像（+ root `securityContext`）；例外仅文档要求的 operator 门槛提示与 Cluster `mixCoord` / 3.0 Cluster 完整 CR。
- 密钥只来自环境变量；决策走选项框；不捆绑二进制；NS 作用域。

## 钉选版本（`upgrade_paths.json` pins）

见 JSON：`bridge_2_5_with_mixcoord`、`recommended_2_6`、`recommended_3_0`、`verified_2_6_to_3_0_source/target`、`min_operator_for_2_5_to_2_6` 等。更新产品钉选时改 JSON 并跑 `python3 scripts/upgrade_paths.py selftest`。
