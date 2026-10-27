# Milvus Agent Skills

面向 Coding Agent（Cursor / Codex / Claude Code / Gemini CLI 等）的 Milvus 运维 Skills。

当前包含：

| Skill | 说明 |
| --- | --- |
| [`milvus-operator-upgrade`](./skills/milvus-operator-upgrade/SKILL.md) | 在 **milvus-operator** 部署的 Milvus 上做一键原地升级（只换 Milvus 镜像）与一键回滚；SSH 密钥优先，否则系统密码弹窗；`milvus-backup` 为前置条件，不内置二进制。 |

安装方式对齐 [mattpocock/skills](https://github.com/mattpocock/skills)：内容放在 GitHub，用官方 `skills` CLI 安装。

## 安装（推荐）

需要本机有 Node.js（`npx`）。在任意项目目录执行：

```bash
# 交互选择 agent / skill
npx skills@latest add yinmin2020/milvus-operator-upgrade

# 或直接指定 skill + 全局安装（各 agent 共用）
npx skills@latest add yinmin2020/milvus-operator-upgrade \
  --skill milvus-operator-upgrade -g
```

常用 agent 落盘路径（`-g` 时）：

| Agent | 全局目录 |
| --- | --- |
| Cursor | `~/.cursor/skills/` 或 `~/.agents/skills/`（以本机 `npx skills` 检测为准） |
| Codex | `~/.codex/skills/` 或 `~/.agents/skills/` |
| Claude Code | `~/.claude/skills/` |

项目内安装（不加 `-g`）会写到当前仓库的 `.agents/skills/`（或对应 agent 目录）。

更新：

```bash
npx skills@latest update
```

### 手动拷贝（无 Node 时）

```bash
git clone https://github.com/yinmin2020/milvus-operator-upgrade.git
cp -R milvus-operator-upgrade/skills/milvus-operator-upgrade ~/.agents/skills/
# 或拷到 ~/.codex/skills/、~/.cursor/skills/ 等你实际使用的目录
```


## `milvus-operator-upgrade` 速览

**适用**

- 命名空间里有 `milvus.io/v1beta1` 的 `Milvus` CR（operator 部署）
- 要**实际执行**原地升级（如 2.6.x → 3.0.x）或升级后回滚

**不适用**

- Helm / docker-compose 部署、首次安装、升级 operator 本身、跨集群迁移
- 只要方案/建议、不执行

**流程（一键）**

1. 问命名空间（必要时再问 master SSH 地址）
2. SSH：密钥 → 系统密码弹窗（Mac/Linux/Windows）→ 手动登录兜底
3. 只读预检；缺 `milvus-backup 0.6.1` 时给出官方下载链接与放置选项（**Agent 绝不代下二进制**）
4. 选项选目标镜像 → 选项确认风险 → 全自动备份 / 升级 / 校验 / 清理
5. 始终关闭 SSH 复用连接


## 流程图

![Milvus Operator 一键升级流程](./docs/upgrade-flow.svg)

可交互版本（可缩放、开启动画）：[upgrade-flow.html](./docs/upgrade-flow.html)

**前置条件**

- 能 SSH 到 K8s master，且该机有 `kubectl` 管理权限（仅操作用户给出的命名空间）
- master 上可用 `milvus-backup` **0.6.1**（架构匹配）；缺失时按 skill 提示自行下载并告知路径

已在测试集群验证：`2.6.25 → 3.0.3` 升级与回滚；NodePort 保持。

细节、触发条件与安全约束见 [`skills/milvus-operator-upgrade/SKILL.md`](./skills/milvus-operator-upgrade/SKILL.md)。

## 仓库布局

```text
skills/
  milvus-operator-upgrade/
    SKILL.md          # Agent 入口
    assets/           # askpass 助手（Mac/Linux/Windows）
    scripts/          # oneshot 升级/回滚、connect、预检等
    references/       # 安装相关备注（升级流程不依赖）
docs/
  upgrade-flow.svg    # README 流程图
  upgrade-flow.html   # 可交互流程图
README.md
LICENSE
.gitignore
```

`npx skills` 会扫描仓库里的 `skills/**/SKILL.md`（以及 `.agents/skills/` 等标准路径）。

## 安全说明

- 密码、token、AK/SK、kubeconfig **不会**通过聊天或选项框收集；SSH 密码走系统弹窗，不进入 Agent 上下文。
- Skill **不内置**、也**不代下** `milvus-backup` 等大二进制。
- 升级只改 Milvus 镜像（外加文档约定的 root securityContext）；etcd / MinIO / operator 镜像不动。
- 操作范围限制在用户指定的命名空间。

## License

MIT（见 [LICENSE](./LICENSE)）。
