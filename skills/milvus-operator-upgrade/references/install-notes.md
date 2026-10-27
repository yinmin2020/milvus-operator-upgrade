# 安装相关笔记（升级/回滚不需要）

> **本文件内容只与首次安装 Milvus / milvus-operator 有关，升级和回滚都用不到。**
> 执行 milvus-operator-upgrade 时，不要据此让用户准备 etcd、MinIO、operator 或 toolImage 镜像，也不要修改 operator。
> 升级只改 Milvus CR 的 `spec.components.image`（外加 root securityContext）；恢复按现有 CR 规格原样重建，依赖沿用原镜像。

1. **toolImage 必须包含 `/init.sh`**：私有仓库场景下可以直接用 operator 镜像本身作为 `spec.components.toolImage`；`helm-kubectl-jq` 之类镜像不可用。安装时设置一次即可，升级不改它。
2. **MinIO 入口是 `silo` 的镜像源**：需要把 MinIO 启动命令改成 `minio server`。做法是对 operator 的 `manager` 容器打 strategic merge patch（不能用 JSON patch 追加 `volumeMounts/-`），而且必须在创建 Milvus CR **之前**打好。这是安装期一次性改动，升级/回滚都不要动 operator。
3. **依赖 deletionPolicy**：安装时 etcd/MinIO 的 `deletionPolicy` 默认 Retain，删除 CR 不会删除 `<CR>-etcd`、`<CR>-minio` helm release 和 PVC。一键恢复脚本会自行处理，安装时无需特别设置。
