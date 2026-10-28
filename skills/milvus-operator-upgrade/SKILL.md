---
name: milvus-operator-upgrade
description: 在 milvus-operator 部署的 Milvus（命名空间里有 milvus.io/v1beta1 Milvus CR）上实际执行原地升级（只换 Milvus 镜像，如 2.6.x → 3.0.x），或在升级后一键回滚/恢复到升级前版本。触发：用户要真正动手“升级 Milvus”“用 operator 升级 Milvus”“Milvus 升到 3.0”“回滚 Milvus”“恢复升级前的 Milvus”，或 “upgrade Milvus (operator / Milvus CR)”“roll back / restore Milvus after upgrade”。流程固定为：只问命名空间 → 用 scripts/connect.sh（Windows 用 connect.ps1）连接 master（密钥优先，否则系统密码弹窗，密码不经过对话） → 只读预检 --check-only（milvus-backup 0.6.1 是前置条件，skill 不携带也不自动安装：缺失时给出官方下载链接，由用户自行下载并用选项告知位置，agent 绝不联网下载） → 用选项选目标镜像 → 用选项确认风险提示 → 全自动执行（临时 SA、备份、升级、校验、报告、清理）。不适用：Helm 或 docker-compose 部署的 Milvus、首次安装、升级 milvus-operator 本身、跨集群迁移、只要升级方案/建议/排障而不执行（这些交给通用 Milvus 运维 skill，如 milvus-ops-expert）。
---

# Milvus Operator 一键升级 / 回滚

## 何时使用 / 不适用

**使用**（同时满足）：
- Milvus 由 milvus-operator 部署：目标命名空间里有 `Milvus` CR（`kubectl get milvus -n <NS>` 有结果）。
- 用户要**实际执行**：原地升级 Milvus 版本（例如 2.6.x → 3.0.x），或升级后回滚/恢复到升级前的版本和数据。
- 典型说法：「升级 Milvus」「operator 升级 Milvus」「把 Milvus 升到 3.0」「回滚 Milvus」「恢复升级前的 Milvus」；“upgrade Milvus on milvus-operator”、“roll back / restore Milvus”。

**不适用**（不要加载本 skill，交给通用 Milvus 运维 skill，例如 milvus-ops-expert）：
- Helm chart 或 docker-compose 部署的 Milvus（没有 Milvus CR）。
- 首次安装 Milvus 或 milvus-operator（安装相关的坑见 `references/install-notes.md`，升级用不到）。
- 升级 milvus-operator 本身、跨集群迁移、换存储/换 MQ。
- 只要升级方案、版本建议、风险评估、排障思路，不实际执行。

**范围**：升级**只改 Milvus 镜像**（外加 root securityContext，见下文），etcd、MinIO、MQ 和 operator 及它们的镜像都不动。**不要**让用户准备 etcd/MinIO/operator/toolImage 镜像，也不要问这些。恢复按现有 CR 规格原样重建，依赖沿用原镜像，同样不用问。所有操作只发生在用户给的命名空间内。

## 交互规则（必须遵守）

- 每个需要用户决定的问题，都用宿主提供的**结构化选项工具**提问：Claude Code 用 `AskUserQuestion`，Codex 用 `request_user_input`（可用时），其他宿主用同类工具。
- 没有这类工具时，列出带编号的选项，让用户回复编号。
- 能用选项就不要让用户自由输入；只有「自定义镜像」「master 地址未知」「milvus-backup 路径」这类确实无法枚举的值才让用户输入（路径不是机密，可用 allowCustom/自定义输入）。
- 不要一次问多个问题；按 A → 连接 → B →（缺 milvus-backup 时 B2）→ C → D → 执行 → 关闭连接 的顺序推进。预检（B）不需要确认，直接执行；B2 必须用选项让用户告知 milvus-backup 的位置。
- **选项框/输入框不是保密通道**：宿主的选项工具（AskUserQuestion、request_user_input 等）不加密，用户的选择和输入会和聊天消息一样进入对话上下文和会话记录。因此框里只能出现非敏感内容（命名空间、CR 名、镜像地址、备份名、确认/取消）。**绝不**用选项框、输入框或聊天向用户索要密码、token、AK/SK、kubeconfig 内容（包括 Milvus 的 `MILVUS_TOKEN` / `MILVUS_TEST_TOKEN`，见「Milvus 鉴权与 RBAC」）。
- **选项框消失或没有回答**：本轮结束时框会消失，用户没有作答，一律视为**未确认/取消**，不得猜测默认值继续，更不得据此启动升级或恢复。用户下一条消息回来后，从当前步骤重新弹出同一个问题；风险确认（D）必须在启动前的同一轮里拿到明确的「确认」。

## 升级流程

### A. 只问命名空间
- 问 `NS`（Milvus CR 所在命名空间）。记忆或对话里已有就直接用。
- master 的 SSH 地址不知道时再问一次（地址不是机密，可以在对话里给；见「连接方式」）。
- 不要问 CR 名、镜像、版本、operator、MQ 等，预检会自动查出来。
- 拿到地址后先按「连接方式」建立连接，再做 B。

### B. 只读预检（`--check-only`）
传脚本到 master（见「执行」第 1 步），然后前台运行：
```bash
<SSH> 'bash /root/milvus-upgrade/skill/scripts/oneshot_upgrade.sh <NS> --check-only [--name <CR>] [--target-tag v3.0.3]'
```
- 只读：只用管理员 kubeconfig 做 get/list 和 `auth can-i`，**不创建任何集群对象，不写任何文件**，不需要目标镜像。
- 输出格式（机器可读）：
  - `CHECK <key>=<value>`：事实，如 `cr`、`cr_mode`、`current_image`、`current_version`、`status`、`milvus_updated`、`paused`、`operator_version`、`mq`、`service_type`、`service_ports`、`image_pull_secrets`、`milvus_backup`、`milvus_backup_version`、`master_arch`、`milvus_backup_url`、`milvus_backup_sha256`、`milvus_backup_bin_sha256`、`disk_avail_bytes`。
  - `CHECK_ITEM <项> <PASS|FAIL|WARN|INFO|MISSING> <说明>`：检查结论。`MISSING` 只用于 `milvus_backup`，不是 FAIL。
  - `PREREQ …`：仅缺 milvus-backup 时出现，给出 master 架构、官方下载链接、期望 sha256 和两种放置方式。
  - `SUGGEST target_image=<当前仓库>:v3.0.3`、`SUGGEST official_image=milvusdb/milvus:v3.0.3`。
  - 一张人读表格，最后一行 `CHECK_RESULT rc=N`。
- 检查项：master 工具、NS、管理员能否建临时 SA/Role/token、CR 及模式、健康（Healthy + MilvusUpdated）、paused、operator 版本、MQ/依赖、Pod Ready、Service 类型与 NodePort（与 CR serviceType 是否一致）、imagePullSecrets、root 运行说明、milvus-backup 是否可用（架构须与 master 一致，架构不符视为未安装）、master 磁盘、NS 锁、版本门槛（官方文档要求当前 ≥ 2.5.16，2.6.0-rc 不支持；目标 3.x 时本 skill 要求当前 ≥ 2.6，已验证 2.6.25 → 3.0.3 @ operator 1.3.12）、目标版本高于当前、鉴权与 RBAC 凭据（`auth_enabled`、`milvus_token`，见「Milvus 鉴权与 RBAC」；开启鉴权但没有可用的 root/admin 凭据 = FAIL）。
- `rc=0`：全部 PASS（WARN/INFO 不阻断），把表格转述给用户，进入 C。
- `rc=4` 且有 `NEEDS install_backup`：其余全部通过，只缺前置条件 milvus-backup（`CHECK_ITEM milvus_backup MISSING`），做 B2。
- `CHECK_ITEM milvus_backup_sha256 WARN`（找到的文件不在已知 0.6.1 清单中）：转述后用选项问「仍然使用（未经验证）/ 取消（换官方 0.6.1，回到 B2）」，选前者才进入 C。
- `rc=2` 且有 `NEED_CR_NAME candidates=a,b`：用选项让用户选 CR（每个候选一个选项），加 `--name` 重跑 B。
- `rc=3`：NS 不存在、没有 Milvus CR 或环境不满足，把说明转述给用户，停止。
- `rc=5`：有 FAIL 项，转述 FAIL 项和修复建议，**不要进入 C**。`milvus_token` FAIL 时告诉用户：在 master 上用自己的终端设置 `MILVUS_TOKEN`（见下节），agent 不得代为设置或索要，然后重跑 B。此时若 milvus_backup 也是 MISSING，可以先做 B2，但 FAIL 项修复前仍不能继续。

### B2. 前置条件 milvus-backup（仅 B 报 MISSING 时）
**绝不**代用户从 GitHub 或任何外网下载 milvus-backup 或其他二进制（本机、master、浏览器都不行），也不要自己在用户磁盘上搜找安装包；只用用户告知的位置。
1. 把 B 输出的 `master_arch`、`milvus_backup_url`（官方下载链接）、`milvus_backup_sha256` 原样告诉用户：请自行下载，放到 master 的 `/root/milvus-upgrade/`（tarball 原名或解出的 `milvus-backup` 二进制，需 `chmod +x`）或 master 其他路径，或下载到自己电脑上。
2. 用选项问（路径用自定义输入）：`已放到 master 默认目录 /root/milvus-upgrade/` / `已放到 master 其他路径（自定义输入路径）` / `已下载到本机（自定义输入本地路径）` / `取消`。选项框消失或未回答 = 取消，停止。
3. 按选择处理：
   - 默认目录：直接重跑 B。
   - master 其他路径：重跑 B 加 `--backup-bin <路径>`；之后正式运行（升级/恢复）也带同样的 `--backup-bin`。
   - 本机：运行下面的安装脚本，rc=0 后重跑 B。
   ```bash
   bash <SKILL_DIR>/scripts/install_backup.sh [--port N] [--workdir <DIR>] <master> --from <本地路径>
   # Windows：powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\install_backup.ps1 [-Key <SSH_KEY>] [-Port N] <master> -From <本地路径>
   #         （mode=tmpkey 时 -Key 填 connect.ps1 输出的 SSH_KEY；走 WSL 时在 WSL 里运行 install_backup.sh）
   ```
   脚本：判断 master 架构 → 对照 `scripts/milvus-backup-sha256.txt` 校验本地文件 → 传到 master 工作目录 → master 上再校验、解出 `<workdir>/milvus-backup`、检查 ELF 架构和二进制 sha256、`--help` 自检（原有文件改名为 `.bak-<时间戳>`）。最后一行 `BACKUP_INSTALL rc=N path=… action=installed|skipped|none arch=… verified=yes|no`。
   rc：0 成功/已存在；1 ssh 不通（重新 connect）；2 路径不存在或参数错（回到第 2 步）；3 架构不符（让用户下载与 `master_arch` 对应的包，回到第 2 步）；5 传输/解压失败、6 自检失败（转述并停止）；4 sha256 不在已知清单、7 版本不是 0.6.1（只验证过 0.6.1）：转述期望/实际值，用选项问 `重新下载官方 0.6.1 后提供新路径（推荐）` / `仍然使用此文件（未经验证，风险自担）` / `取消`，只有选第二项才加 `--allow-unverified`（ps1：`-AllowUnverified`）重跑。
4. 重跑 B 只有 `rc=0` 才进入 C；仍是 `rc=4` 时转述 MISSING 说明里的不可用原因（如架构不符、无执行权限），回到第 2 步。

### C. 选择目标镜像（预检通过后）
用结构化选项提问，选项固定为（`<repo>` 取自 `SUGGEST target_image` 去掉 tag）：
1. 沿用当前仓库 `<repo>:v3.0.3`（推荐）
2. 官方 `milvusdb/milvus:v3.0.3`
3. 自定义输入（只有选了这一项才让用户输入完整镜像地址）

用户选了 2 或 3 时，镜像与 B 预检里的 tag 不同，就带上该镜像再跑一次 `--check-only <NS> <镜像>`，确认版本门槛仍然 PASS。

### D. 风险提示 + 确认
把下面的风险提示原样展示（替换 `<NS>` `<TARGET_IMAGE>`），再用结构化选项问：`确认升级` / `取消`。只有选了「确认升级」才启动（带 `--yes`），其他任何回答都视为取消。

```
================ 风险提示 ================
将对命名空间 [<NS>] 中的 Milvus 原地升级到 [<TARGET_IMAGE>]，全程无人值守，任一关卡失败即停止：
1. 修改 Milvus CR：spec.components.image=目标镜像（只换 Milvus 镜像，etcd/MinIO/MQ 及其镜像不动），
   并设置 spec.components.securityContext={runAsUser:0, runAsNonRoot:false}（容器以 root 运行）。
   【与官方文档的差异】官方只 patch spec.components.image；这里额外改为 root，因为 2.6 写入的 rocksmq/缓存文件属主是 root，
   3.0 镜像默认非 root 用户启动会 Permission denied/CrashLoop。若安全策略不允许 root 容器，请取消。
   Service 为 NodePort/LoadBalancer 时把 CR 的 serviceType 固定为同类型（nodePort 漂移则改回快照值）。
2. 在 [<NS>] 临时创建 SA/Role/RoleBinding "milvus-upgrader" 和短期 token，结束（含失败）自动删除；之后所有操作都用该 SA 身份执行。
3. 用 milvus-backup 做全量备份 pre_upgrade_<时间戳>（始终带 --rbac：用户、角色、授权一并备份；备份含密码哈希，仅存放在 MinIO 和 master 本地导出里），
   写入该 Milvus 的 MinIO 桶（backup/ 前缀），不自动删除；并完整导出一份到 master 本地（MinIO 被删后仍可用 oneshot_restore.sh 恢复；会先检查磁盘空间）。
4. 在 [<NS>] 临时创建拉取检查 Pod（milvus-upgrader-pullcheck-N），固定到 Milvus 所在节点，用完即删。
5. 3.0 无法通过改回镜像回滚，只能从备份恢复到新实例；升级期间 Milvus 有短暂停机（standalone 实测 patch→Healthy 约 65 秒，镜像已预拉取）。
6. 若实例开启了鉴权：使用环境变量 MILVUS_TOKEN（root/admin 账号）读取/备份 RBAC，升级前后各取一份 RBAC 快照比较；不一致时结果为“部分”（退出码 14），不报告成功。
除上述对象外，不修改 [<NS>] 内其他资源，也不在任何其他命名空间创建或修改对象（由 SA 权限在 API Server 层强制）。
==========================================
```

脚本启动时会在日志里再打印同样的内容。

## 连接方式

agent 以 **root** SSH 登录 **master**（master 上要有 kubectl 和管理员 kubeconfig，默认 `~/.kube/config`，可用 `ADMIN_KUBECONFIG` 覆盖；还需 bash、python3≥3.6、flock、ss、tar、base64）。master 地址从用户已有 SSH 配置或记忆获取，没有就问一次；**不要写进 skill**。

**安全规则（必须遵守）**
- 密码只能由用户在**系统弹窗或用户自己的终端**里输入。绝不通过聊天、选项框、输入框、文件、命令行参数、环境变量或任何 agent 能看到的输出传递；不得要求用户把密码发给你。
- 不得读取、打印、记录任何密码；不得自己运行、包装、改写 `assets/askpass_*` 助手，不得重定向或捕获它们的输出，只能由 connect 脚本交给 ssh 调用。
- 首次使用前（以及每次会话开始时）先校验下表 6 个文件的 sha256（Mac：`shasum -a 256 <SKILL_DIR>/scripts/connect.* <SKILL_DIR>/assets/askpass_*`；Linux：`sha256sum`；Windows：`Get-FileHash -Algorithm SHA256`）。任何一个不符就停止并告诉用户，不得继续连接。connect 脚本还会自查助手哈希，不符时退出 23。
- 弹窗前先告诉用户「即将弹出系统密码框，请在弹窗里输入 master 的密码」。弹窗被关闭或超时 = 取消。

| 文件 | sha256 |
|---|---|
| scripts/connect.sh | `080e8d54c7518f63797a50786208b5a9df59b5ed6b7cb189816df0f13a6a592b` |
| scripts/connect.ps1 | `e27e232403ff67ce6894128361b2d98ac8c3cccb83296f031f6cfcf45943450a` |
| assets/askpass_mac.sh | `da5dcd82e5a18cf8e329516a9641030a85ae95424ac3a3e71710a8736abadff5` |
| assets/askpass_linux.sh | `506b212a432a25df55e57cb974a9aaa4a5ccc9c4cff6f6ca4f0efa187f68903c` |
| assets/askpass_win.cmd | `204a735f0a248e7974289746a5cd6403829b6d3a115f5526636d5b7e207b01bc` |
| assets/askpass_win.ps1 | `218b2b511f80991adf0140043243a4383b9a7fdd12af1516c71e3817b2532a70` |

**连接顺序**（脚本自动按此执行）：
1. 密钥登录（`BatchMode`，不会提示输入）。成功后同时开一个后台复用连接。
2. 系统密码弹窗：ssh 经 `SSH_ASKPASS`（`SSH_ASKPASS_REQUIRE=force`，需 OpenSSH ≥ 8.4）调用弹窗，只登录一次并建立 ControlMaster（`ControlPath=~/.ssh/cm-%r@%h:%p`，`ControlPersist=2h`），之后的 ssh/scp 都复用这条连接，不再要密码。Windows 自带 OpenSSH 不支持 ControlMaster，改为：弹窗输入一次密码 → 往 master 的 `authorized_keys` 追加一把临时公钥（标记 `milvus-upgrade-tmp-<时间戳>`）→ 之后用临时密钥。
3. 以上都不行时退出 20，打印一条让用户在**自己的终端**运行的命令。

| 本机 | 建立连接 | 弹窗方式 | 关闭连接 |
|---|---|---|---|
| macOS | `bash <SKILL_DIR>/scripts/connect.sh <master>` | `osascript` 隐藏输入对话框 | `bash <SKILL_DIR>/scripts/connect.sh --close <master>` |
| Linux 桌面 | 同上 | zenity / kdialog / ssh-askpass（需 `DISPLAY` 或 `WAYLAND_DISPLAY`；无图形界面直接退出 20） | 同上 |
| Windows（未实测） | `powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\connect.ps1 <master>` | WinForms 遮蔽输入框 + 临时密钥 | `... connect.ps1 -Close <master>`（删除远端那一行公钥和本机临时密钥） |

可选参数：`--port N`（ps1：`-Port N`）；只检查：`--check`（`-Check`）；只打印手动命令：`--manual`（`-Manual`）。

**按退出码处理**（输出最后一行是 `CONNECT_RESULT rc=N mode=…`）：

| rc | 含义 | agent 的处理 |
|---|---|---|
| 0 | 已连接，`mode=key/controlmaster/tmpkey` | 记下输出里的 `SSH_OPTS=`，进入 B |
| 10 | 用户取消或弹窗超时 | 视为取消，停止；用户回来后可重试 |
| 11 | 密码连续 3 次错误 | 告诉用户，问「重试 / 取消」 |
| 20 | 需要手动登录（无图形界面、ssh 太旧、弹窗不可用等） | 把脚本打印的命令原样展示给用户，用选项问「已登录 / 取消」；选「已登录」后运行 `connect.sh --check <master>`（Windows `-Check`），rc=0 才继续 |
| 21 | 首次连接，主机指纹未知 | 展示输出里的 `HOSTKEY_FP` 行，用选项问「指纹无误，接受 / 取消」；接受后加 `--accept-new-hostkey`（`-AcceptNewHostKey`）重跑 |
| 22 | 主机指纹已变化 | 停止，告诉用户可能有中间人或 master 重装，由用户自行处理 |
| 23 | 助手脚本哈希不符 | 停止，不要连接 |
| 25 | （Windows）检测到 WSL | 按输出在 WSL 里运行 `connect.sh`，之后所有 ssh/scp 都用 `wsl -e …` 在 WSL 中执行；不想用 WSL 时加 `-NoWsl` 重跑 |
| 30 | 网络/端口/SSH 错误 | 转述错误，停止 |
| 1 / 2 | 未连接 / 参数错误 | 按提示修正 |

**之后的 ssh/scp**：把 `SSH_OPTS` 里的选项**逐字写进命令**（不要放进 shell 变量再展开，zsh 不会分词）。Mac/Linux（有 `--port` 时再加 `-o Port=N`）：
```bash
ssh -o ControlPath=~/.ssh/cm-%r@%h:%p -o BatchMode=yes root@<master> '<cmd>'
scp -o ControlPath=~/.ssh/cm-%r@%h:%p -o BatchMode=yes -r <本地路径> root@<master>:<远端路径>
```
Windows（tmpkey）：`ssh -i "<SSH_KEY>" -o IdentitiesOnly=yes -o BatchMode=yes root@<master> '<cmd>'`，scp 同样。下文 `<SSH>` 即上面的 ssh 前缀，`<SCP>` 即 scp 前缀。

**结束时必须关闭连接**：升级/恢复结束（成功、失败或用户取消）后，运行 `connect.sh --close <master>`（Windows `connect.ps1 -Close <master>`）。注意：后台运行的升级脚本不依赖这条连接，关闭不影响 master 上的任务；但轮询结束前不要关闭。

## Milvus 鉴权与 RBAC（authorizationEnabled=true）

问题背景：恢复会删除 CR 和 etcd/MinIO 的 PVC，而 Milvus 的用户、角色、授权存在 etcd 里。不备份 RBAC，回滚后这些全部丢失（issue #1）。因此：

- **备份/恢复始终带 `--rbac`**（milvus-backup 的 `create --rbac` / `restore --rbac`）。未开启鉴权时同样带，对空的 RBAC 无害。
- **开启鉴权时必须有 root/admin 凭据**：读写用户、角色、授权需要管理员权限。凭据**只来自 master 上的环境变量**，格式 `user:password`：
  - `MILVUS_TOKEN=root:<密码>`；或 `MILVUS_TOKEN_FILE=<文件>`（文件权限必须是 600/400，第一行 `user:password`，由用户自己在终端里创建）。
  - 凭据不能经聊天、选项框、命令行参数传递；日志、报告、命令行都不会出现密码。用户要在自己的终端里 `ssh master`，`export MILVUS_TOKEN=…` 后自己运行脚本；或先写好 600 权限的 token 文件，再让 agent 带 `MILVUS_TOKEN_FILE=<路径>` 运行。agent 看不到文件内容。
  - `--check-only` 会验证：开启鉴权但没有凭据、文件权限过宽、账号不是管理员 → `milvus_token` FAIL（rc=5），升级/恢复在改动前拒绝启动。
  - 恢复后 milvus-backup 不会恢复 root 的密码（root 已存在，被跳过），脚本会用 `MILVUS_TOKEN` 的密码把 root 改回备份时的值，再继续。
- **验证**：升级前（及恢复前）用 REST 快照用户、角色、用户-角色绑定、授权（`probe.py rbac-snapshot`，600 权限，只含名称和授权条目，不含密码）；升级后/恢复后再比较（`rbac-compare`）。不一致 = 关卡 FAIL，退出码 14（升级：`ONESHOT PARTIAL`；恢复：部分恢复），**绝不报告“完整恢复/成功”**。
- **可选应用用户检查**：`--rbac-test [--rbac-test-collection <集合>] [--rbac-test-deny list_users,create_collection]`，另需环境变量 `MILVUS_TEST_TOKEN=appuser:password`（或 `MILVUS_TEST_TOKEN_FILE`）。脚本用该自定义应用用户在升级后/恢复后做一次允许的操作（对集合 query）和被禁止的操作（默认 `list_users`，可选 `create_collection`），允许成功且禁止被拒才 PASS；用户权限过大（禁止的操作成功）也算 FAIL。
- **旧备份没有 RBAC 元数据**（在本修复之前做的备份）：恢复只能恢复数据。脚本在**删除任何东西之前**检查，开启鉴权且备份不含 RBAC 时退出 5 并打印 `RBAC_DECISION_NEEDED`；预检也会给 `backup_rbac` WARN 和同样的标记。此时必须用**选项框**问用户（见恢复流程 D）。
- 升级脚本在备份后检查备份元数据里确有 `rbac_meta`（milvus-backup 0.6.x 写在 `meta/full_meta.json`，旧版本在 `backup_meta.json`）（开启鉴权时，读 MinIO 中的备份，与 `--no-export` 无关），没有则退出 6，不会改镜像。

## 前置条件：milvus-backup 0.6.1

- 本 skill 只验证过 milvus-backup **0.6.1**，skill 不携带也不下载它；需要用户从官方 release（https://github.com/zilliztech/milvus-backup/releases/tag/v0.6.1）下载 `milvus-backup_0.6.1_Linux_x86_64.tar.gz` 或 `milvus-backup_0.6.1_Linux_arm64.tar.gz`（与 master 架构一致）。
- 已知 sha256（tarball 与解出的二进制）见 `scripts/milvus-backup-sha256.txt`，仅用于完整性校验；预检和 `install_backup.*` 都读这个文件。

## 执行

`<SKILL_DIR>` 是本 skill 所在目录，`<SSH>`/`<SCP>` 见「连接方式」。

1. 传输脚本（B 之前做一次，可重复执行）：
   ```bash
   <SSH> 'mkdir -p /root/milvus-upgrade/skill && chmod 700 /root/milvus-upgrade'
   <SCP> -r <SKILL_DIR>/scripts root@<master>:/root/milvus-upgrade/skill/
   ```
2. D 确认后后台启动。nohup 必须是一条独立的命令，不要接在 `&&` 链后面，否则 ssh 会一直挂到脚本结束：
   ```bash
   <SSH> 'nohup bash /root/milvus-upgrade/skill/scripts/oneshot_upgrade.sh <NS> <TARGET_IMAGE> --yes [--name <CR>] [--backup-bin <路径>] [--probe-collection <集合>] [--rbac-test …] > /root/milvus-upgrade/last_run.out 2>&1 < /dev/null &'
   ```
3. 每 30 到 60 秒轮询一次，直到出现 `ONESHOT_RESULT rc=<N> run_dir=<目录>`：
   ```bash
   <SSH> 'tail -n 30 /root/milvus-upgrade/last_run.out'
   ```
   期间可以把关卡进度简短转述给用户。实测从启动到结束约 2 分钟，其中升级约 65 秒。镜像需要现场拉取时会更久。
4. `rc=0` 时，读取 `<run_dir>/report.md` 并把结果表发给用户，内容包括：镜像前后、CR 状态、Service/nodePort 前后、备份名和位置、探针结果、各关卡、耗时。同时提醒用户保留备份，直到业务确认无误。
5. 无论结果如何（成功、失败、取消），最后关闭连接（见「连接方式」）。

可选参数（用户没提就不问）：`--rbac-test`（及 `--rbac-test-collection`、`--rbac-test-deny`，见「Milvus 鉴权与 RBAC」）、`--name <CR>`、`--backup-bin <路径>`（默认依次查找 `/root/milvus-upgrade/milvus-backup`（B2 放置/安装位置）、`/root/milvus-backup/milvus-backup`、`/usr/local/bin`、`PATH`，以及 `/root/milvus-upgrade/` 或 `/root/` 下的 `milvus-backup_*_Linux_*.tar.gz`；架构与 master 不符的自动跳过）、`--probe-collection <已 load 的集合>`、`--export-dir <目录>` / `--no-export`（跳过后一键恢复只能依赖 MinIO 里仍在的备份）、`--operator-ns`、`--upgrade-timeout 1200`、`--pull-timeout 900`、`--token-ttl 3h`、`--workdir /root/milvus-upgrade`、`--target-tag v3.0.3`（仅 `--check-only`）。

下列信息自动获取，不要问用户：CR 名（NS 内只有一个时）、standalone 或 cluster、当前镜像、MQ 类型、operator 位置、版本和镜像、imagePullSecrets、Milvus 所在节点、MinIO 和 etcd 的地址、bucket 与 rootPath（读 `<CR>` ConfigMap 的 user.yaml，不用 CR 里的 chart 值）、Service 快照。

脚本内部按以下顺序执行，任一步失败都会停止，并进入清理：
0. 环境检查（admin）：加 NS 锁（`/root/milvus-upgrade/.lock-<NS>`）、确认 NS 存在、确认 admin 有建 SA/Role/token 的权限、只读定位 operator。
1. 第一阶段 RBAC：SA 只能在 NS 内 get/list milvuses。签发短期 token，在 0700 临时目录生成 600 权限的 kubeconfig，然后 `export KUBECONFIG=<SA>`，之后的 kubectl 都以 SA 身份运行。用 SA 发现 CR。
2. 第二阶段 RBAC：patch 只限 `milvuses/<CR>` 和 `services/<CR>-milvus`；pods delete 只限 `milvus-upgrader-pullcheck-0..9`；configmaps 只能 get `<CR>`；允许 pods/portforward。不授予 secrets、exec，也不授予任何集群级权限。
3. 隔离自检：一组 can-i 的 yes/no 断言，再实际执行 `get pods -n kube-system` 和 `create configmap -n kube-system --dry-run=server`，两者都必须返回 Forbidden，否则以退出码 4 停止。
4. 预检（与 `--check-only` 相同的门槛，再查一遍）：CR 为 Healthy、`MilvusUpdated=True`、未 paused；版本门槛（当前 ≥ 2.5.16、非 2.6.0-rc、不降级、升 3.x 时当前 ≥ 2.6）；Service 类型与 CR serviceType；保存 Service 快照和 cr-before.yaml。CR 已是目标镜像且 Healthy 时进入 ALREADY 模式，只做校验。
5. 镜像拉取检查：在每个 Milvus 节点上建一个临时 Pod，用 nodeName 固定，带 CR 的 imagePullSecrets，运行 `/bin/sh -c "exit 0"`。出现 ImagePullBackOff 或 ErrImagePull 即失败。
6. 以 SA 身份 port-forward：只绑定 127.0.0.1，本地端口避开 2379（41953/41909/49000/42379，被占用时自动顺延）。运行升级前探针。
5b. 鉴权实例：`probe.py rbac-check`（账号须为管理员，否则退出 5）、`rbac-snapshot`（`rbac_pre.json`）、可选 `rbac-authtest`（升级前基线）。
7. milvus-backup：依次 check、`create --rbac -n pre_upgrade_<TS>`（输出必须含 success）、list、get，并用 `s3tool.py`（标准库 SigV4）列出 MinIO `backup/<name>/` 下的对象（对象数必须大于 0）；开启鉴权时再用 `s3tool.py rbacmeta` 确认备份含 RBAC 元数据（否则退出 6）。
7b. 导出：检查磁盘（可用 ≥ 备份大小×1.2 + 1GiB），`s3tool.py pull` 到导出目录并写 MANIFEST（size/sha256/key），对象数必须一致；写 `backup.meta`（NS、CR、备份名、源/目标镜像、导出目录、探针集合与探针结果路径），供恢复脚本自动发现。
8. 升级：按需固定 serviceType，nodePort 有漂移时按快照 patch 回去；用一次 merge patch 改镜像并设置 securityContext。之后每 10 秒检查一次，每 30 秒打印一次进度，直到 Healthy、`MilvusUpdated=True`、currentImage 等于目标镜像、所有 Pod 都换成新镜像并 Ready。CrashLoop 且重启次数 ≥ 3 时打印 `logs --previous` 并退出 7；patch 300 秒后仍处于 ImagePullBackOff 或整体超时（默认 1200 秒）也退出 7。
9. 校验：运行 `verify.sh`，加 `milvus.io/reconcile` 注解，等 40 秒后再运行一次 `verify.sh`。
10. 升级后探针：行数必须一致；top-k id 一致即通过。HNSW 等近似索引重建后 top-k 尾部可能变化，此时改为近似校验：探针行向量逐值一致、top-1 一致、重叠 >= ceil(0.6·k)。
10b. 鉴权实例：`rbac-compare`（与升级前快照逐项比较）和可选 `rbac-authtest`；不一致 → 退出 14。
11. 报告：生成 `report.md`，打印 `ONESHOT OK`。
最后由 trap 清理（成功或失败都会执行）：结束 port-forward（按 PID，再按本次 SA kubeconfig 路径兜底 pkill，并在日志打印残留数，应为 0），删除拉取检查 Pod，删除 SA/Role/RoleBinding（token 随 SA 一起失效），删除临时目录（kubeconfig、MinIO 凭据、milvus-backup 配置和解压出的二进制）。最后打印 `ONESHOT_RESULT`。

日志和产物在 `/root/milvus-upgrade/runs/<NS>-<TS>/`：run.log、report.md、svc_snapshot.txt、svc_after.txt、cr-before.yaml、cr-after.yaml、rbac.yaml、backup_*.out、milvus-backup.log、probe_*.json、probe_state.json（600，探针向量）、backup.meta、backup_export/。其中不含 token 和密钥。report.md 末尾给出对应的一键恢复命令。

### 管理员（root kubeconfig）context 的全部用途及原因

除下表列出的用途外，所有 kubectl 调用都通过 SA 的 `KUBECONFIG` 执行，跨命名空间的操作会被 API Server 拒绝。

| 用途 | 为什么 SA 做不到 |
|---|---|
| `--check-only` 预检：NS 内 get/list（milvus、pods、svc）、`auth can-i`、只读定位 operator Deployment | 预检发生在任何 SA 创建之前，且按要求不创建任何对象；不读 Secret |
| `get ns <NS>`，以及对 SA/Role/RoleBinding/token 的 `auth can-i` | 这些检查发生在 SA 创建之前 |
| 创建、收紧、删除 NS 内的 SA/Role/RoleBinding（`gen_rbac.sh \| kubectl apply`，trap 中 delete） | SA 不能给自己授权；按设计，删除也由创建者完成 |
| `kubectl create token`，以及读取 admin kubeconfig 中的 server/CA | 签发 SA token 本身需要更高权限 |
| 只读查询一次 operator 的 Deployment（`get deploy -A -l app.kubernetes.io/name=milvus-operator`，给了 `--operator-ns` 则只查该 NS），用于报告 operator 的命名空间和镜像 | 需要跨命名空间读取，而 SA 只限于 NS；这一步只读、不建任何对象，operator 版本另以 CR 标签 `milvus.io/operator-version` 为准 |
| 仅当 `<CR>` ConfigMap 中没有 MinIO AK/SK 时：读取 CR `spec.dependencies.storage.secretRef` 指定的那一个 Secret 的 accesskey/secretkey，写入 600 临时文件，trap 中删除 | 按设计不给 SA 读 secrets 的权限（防止读到 NS 内其他 Secret）；admin 只按名字读这一个 |

## 失败处理

| 退出码 | 含义 | 处理 |
|---|---|---|
| 0 | 成功（包括 ALREADY 模式） | 转述 report.md |
| 2 | 参数错误，或需要选择 CR（`NEED_CR_NAME`） | 用选项让用户选 CR，加 `--name` 重跑 |
| 3 | 环境问题：没有 kubectl 或 admin 权限、NS 或 CR 不存在、同一 NS 已有一次运行持有锁 | 按提示修复后重跑 |
| 4 | SA 权限超出预期，例如存在绑定到 `system:serviceaccounts` 的集群级权限 | 停止，交给集群管理员排查，不要绕过 |
| 5 | 预检失败：不健康、paused、版本门槛、Service 与 CR 不一致、镜像拉不下来、探针集合未 load、开启鉴权但缺少 root/admin 的 `MILVUS_TOKEN` 或账号无管理员权限 | 按日志修复，未做任何变更 |
| 6 | 备份失败（含开启鉴权时备份里没有 RBAC 元数据），或找不到 milvus-backup | 未升级；缺 milvus-backup 时回到 B2（前置条件：给出下载链接，用选项问放置位置）后重跑，其他按日志修复存储 |
| 7 | 升级失败：超时、CrashLoop、拉取失败 | CR 已改镜像。看日志里的 `logs --previous`，对照附录「坑」处理；不要把镜像改回旧版，用户决定回滚时走「一键恢复」 |
| 8 | 升级后校验失败，例如 nodePort 被改 | 看 verify 的 diff，用 `kubectl patch svc` 按 svc_snapshot.txt 改回 |
| 9 | 探针不一致 | 停止写入流量，保留现场，由用户决定是否走「一键恢复」 |
| 14 | 升级后 RBAC（用户/角色/授权）与升级前不一致，或应用用户检查失败。结果是 `ONESHOT PARTIAL` | 不要报告成功；转述 `RBAC DIFF` 行（只有名称，无密码），由用户决定修复或走「一键恢复」 |
| 130 | 中断，或未确认 | 无需处理（trap 已清理） |

失败后只要报告退出码、日志中的最后一个错误，以及 run_dir。脚本可以重复执行：修复问题后用同样的参数再跑；CR 已经是目标版本且 Healthy 时会进入 ALREADY 模式，只做校验。

## 一键恢复 / 回滚（oneshot_restore.sh）

**何时用**：升级后业务验证不通过、探针不一致（退出码 9）、或升级失败（退出码 7）且需要回到旧版本时。3.x 写过的数据不能用旧镜像直接读，**不要手工把镜像改回旧版**，只能走本流程。是否回滚由用户决定；agent 不得在升级失败后自动发起恢复。

交互与升级相同（A → B → C → D，全部用结构化选项）：

**A. 只问 NS**（master 地址未知时再问一次），然后按「连接方式」连接。

**B. 只读预检**（不创建任何对象、不写文件）：
```bash
<SSH> 'bash /root/milvus-upgrade/skill/scripts/oneshot_restore.sh <NS> --check-only [--name <CR>]'
```
输出 `CHECK`/`CHECK_ITEM` 行、每个可用备份一行 `BACKUP index=N name=… source_image=… target_image=… export=… objects=… probe=… meta=…`（最新在前）、`rbac=yes|no|unknown`（该备份是否含 RBAC 元数据，只数数量）、`SUGGEST restore_image=…`（最新备份的升级前镜像）、`SUGGEST backup=…`、表格和 `CHECK_RESULT rc=N`。检查项包括：鉴权与 `MILVUS_TOKEN`（同升级）、CR、当前状态（仅 INFO，恢复不要求健康）、依赖（外部 etcd/对象存储/MQ 或 rocksmq existingClaim 时 FAIL，不支持一键恢复）、Service、milvus-backup、磁盘、锁、备份（本地导出副本可用为 PASS）。CR 不存在但有上次中断的恢复记录时提示续跑。`rc` 含义同升级预检（`rc=4` 同样走 B2，再重跑）；`NEED_CR_NAME` 时用选项选 CR。

**C. 选择恢复点**：用结构化选项列出 `BACKUP` 行（每个备份一个选项，标签写「`<name>` → 镜像 `<source_image>`」，第一项标「推荐」），外加「自定义恢复镜像」。恢复镜像默认取所选备份的 `source_image`，不要另外问 etcd/MinIO 等镜像（沿用原 CR）。没有 `BACKUP` 行时，脚本会用 MinIO 中最新的 `pre_upgrade_*`，这时恢复镜像需要用户在选项「沿用当前仓库 `<repo>:<升级前 tag>`」与「自定义输入」之间选择。

**D. 风险提示 + 确认**：原样展示下面的提示（替换 `<NS>` `<RESTORE_IMAGE>` `<BACKUP>`），用选项问 `确认删除当前实例并恢复` / `取消`，只有前者才启动。
```
================ 风险提示（恢复/回滚） ================
将把命名空间 [<NS>] 中的 Milvus 恢复为镜像 [<RESTORE_IMAGE>] + 备份 [<BACKUP>]，全程无人值守：
1. 【不可逆】删除 [<NS>] 中当前的 Milvus CR 及其全部数据：Milvus Pod、Service（随后按原 nodePort 重建）、
   该实例的 etcd 与 MinIO（helm release 由 operator 卸载）以及这些组件挂载的 PVC。删除前当前实例里的数据将永久丢失。
2. 【数据丢失】只能恢复到备份时间点：备份之后写入/删除/修改的数据全部丢失（含升级后写入的数据）。
3. 开启鉴权时：RBAC（用户/角色/授权）随备份一起用 --rbac 恢复；备份不含 RBAC 时（见 D2）它们会丢失，结果为部分恢复。root 密码按 MILVUS_TOKEN 改回。
   用原 CR 配置在旧镜像上重建（etcd/MinIO 等依赖沿用原 CR 里的配置与镜像，不需要另外准备；容器以 root 运行：
   securityContext runAsUser=0——官方文档没有这一步，因为原数据文件属主是 root；保持 serviceType 与原 nodePort），等待 Healthy 后
   把备份（优先使用 master 本地导出副本；若只在 MinIO 中则先导出到 master 本地再删除）导入新 MinIO，用 milvus-backup restore
   恢复全部集合并重建索引、加载集合，与备份时记录的探针（行数 + top-5）比对。
4. 在 [<NS>] 临时创建 SA/Role/RoleBinding "milvus-upgrader"（含删除/创建该 Milvus CR 与删除上述 PVC 的权限）及拉取检查 Pod，结束自动删除。
5. 期间 Milvus 完全不可用（删除 + 重建 + 导入，取决于数据量）。除上述对象外不修改 [<NS>] 内其他资源，也不触碰其他命名空间。
=======================================================
```

**D2. RBAC 决策（仅当 B 输出 `RBAC_DECISION_NEEDED`，即实例开启了鉴权而所选备份不含 RBAC 元数据时）**：先把 C 的恢复点换成含 RBAC 的备份（若有，`BACKUP` 行 `rbac=yes`）。没有时，必须用结构化选项问，且在确认 D 之前问：
- 选项 1：`取消，不恢复`（推荐；不加 `--yes`，什么也不删）
- 选项 2：`继续，仅恢复数据（用户/角色/授权会丢失，需之后手工重建，结果为部分恢复 rc=14）`——只有选了它才在启动命令里加 `--accept-rbac-loss`。
选项框消失或没有回答 = 取消。没有 `--accept-rbac-loss` 时脚本在删除之前退出 5，不会做任何破坏性操作。选了继续后，最终报告也必须按“部分恢复”转述，不得说“完整恢复”。

**启动**（与升级相同的传输、后台启动和轮询方式）：
```bash
<SSH> 'nohup bash /root/milvus-upgrade/skill/scripts/oneshot_restore.sh <NS> <RESTORE_IMAGE> --yes [--name <CR>] [--backup <名>] [--accept-rbac-loss] [--rbac-test …] > /root/milvus-upgrade/last_restore.out 2>&1 < /dev/null &'
```
轮询直到 `ONESHOT_RESULT rc=<N> run_dir=<目录>`，rc=0 时转述 `<run_dir>/report.md`（rc=14 也要转述，但按“部分恢复”，列出 RBAC 差异）；结束后（无论结果）关闭连接。实测（standalone、5000 行、镜像已在节点上）：删除 49 秒、重建到 Healthy 65 秒、导入+restore+load 25 秒，总计约 3 分 25 秒；nodePort 保持不变，探针行数与 top-5 一致，备份后写入的行按预期丢失。

可选参数：`--accept-rbac-loss`（仅在用户于 D2 选了“继续，仅恢复数据”时）、`--rbac-test`（含 `--rbac-test-collection`、`--rbac-test-deny`）、`--name <CR>`、`--backup <名>`（默认：本 NS/CR 最近一次升级 run 的 `backup.meta`，其次 `milvus-backup list` 中最新的 `pre_upgrade_*`）、`--backup-bin`、`--probe-collection`（默认取 backup.meta 中记录的探针集合）、`--restore-timeout 3600`、`--healthy-timeout 1200`、`--pull-timeout`、`--token-ttl 4h`、`--workdir`、`--yes`。

**脚本内部顺序**（任一步失败即停止并清理）：
0. 环境检查、NS 锁（与升级共用 `.lock-<NS>`，两者不能并发）。
1. 第一阶段 SA（只读 milvuses）发现 CR；CR 不存在时进入**续跑模式**（见下）。
2. 预检：保存 cr-original.json/yaml、svc_snapshot.txt；etcd/storage/MQ 为外部依赖或 rocksmq 用 existingClaim 时拒绝（退出 5）。
3. 选择备份并确认可用：优先本地导出副本；没有则先从现网 MinIO 导出到 `<run_dir>/backup_export`；用 MANIFEST 校验 size/sha256（关卡 `backup_ready`）。记录删除前行数（count_before）；开启鉴权时 `rbac-check`、`rbac-snapshot`（删除前的 RBAC 快照）、检查备份含 RBAC 元数据（不含且没有 `--accept-rbac-loss` → 退出 5）。**到此为止未做任何删除。**
4. 生成 cr-recreate.json：去掉 status/运行时字段和 `milvus.io/*`、last-applied 注解，镜像换成 RESTORE_IMAGE，securityContext 设为 root；其余配置（serviceType、依赖配置及其镜像、资源等）原样沿用现有 CR，不需要用户提供。
5. 计算实例 PVC：该实例 Pod（instance/release 标签为 `<CR>`、`<CR>-etcd`、`<CR>-minio`、`<CR>-pulsar`、`<CR>-kafka`）挂载的 PVC 及带这些标签的 PVC；任一 PVC 被其他 Pod 使用则停止。
6. 第二阶段 RBAC（restore 模式）+ 隔离自检：可 delete `milvuses/<CR>`、create milvuses、按名字 delete 上述 PVC；对其他 CR/PVC、deployments、secrets、exec、kube-system、default、nodes 必须为 no，外加两项真实 Forbidden 测试。
7. 镜像拉取检查（RESTORE_IMAGE）。
8. 删除：把 CR 的依赖 deletionPolicy 改为 Delete 并开启 pvcDeletion，删除 CR，等待 CR/Pod/sts/deploy/PVC 消失（最长 900 秒）；CR 消失 90 秒后 PVC 仍在则由 SA 按名字删除（关卡 `delete`）。
9. 重建：create cr-recreate.json，等待 Healthy 且镜像为 RESTORE_IMAGE；按快照把 nodePort patch 回原值（关卡 `recreate`）。
10. 数据恢复：`s3tool.py push` 把本地副本导入新 MinIO，`milvus-backup list` 确认可见，`milvus-backup restore -n <备份> --rebuild_index --rbac`（超时 RESTORE_TIMEOUT；备份不含 RBAC 时不带 --rbac）；用 `rbac-login` 判断新实例是用备份密码还是默认 root:Milvus，再 `rbac-fixroot` 把 root 改回 MILVUS_TOKEN 的密码，然后 load 全部集合（关卡 `restore_data`）。
11. 探针：与升级前探针比对行数和 top-5 id。
11b. RBAC：`rbac-compare` 与删除前快照比较（无快照时只比较数量），可选 `rbac-authtest`；不一致或备份不含 RBAC → 关卡 `rbac` FAIL，退出 14。
12. verify.sh 两次（中间加 reconcile 注解），生成 report.md，打印 `ONESHOT OK`；trap 清理与升级相同。

**退出码**：0 成功；2 参数/需要 `--name`；3 环境；4 隔离自检失败；5 预检失败（**未删除任何东西**）；10 删除阶段失败；11 重建失败；12 数据恢复失败；13 校验失败；9 探针不一致；**14 部分恢复**（数据已恢复，但 RBAC 未恢复或与删除前不一致，报告标题为“部分恢复”，打印 `ONESHOT PARTIAL`，**不得说完整恢复**）；130 中断/未确认。

**续跑模式**：删除之后（退出码 10/11/12）失败时，日志会打印续跑提示。修复原因后用同样的参数重跑即可：脚本发现 CR 已不存在，会使用最近一次 `runs/<NS>-restore-*/cr-recreate.json` 和 restore.meta 继续重建与恢复，无需再次确认风险提示（NS、镜像、备份不变时）。

**仍需用户决定的事项**（都用选项问，除连接回退外，用户不需要手动执行任何命令）：
- 是否回滚、回到哪个备份/镜像（C）以及最终确认（D）。（连接 master 时用户可能需要在系统弹窗或自己的终端里输入一次密码，见「连接方式」。）
- 开启鉴权时，备份不含 RBAC 的情况下是否“仅恢复数据”（D2 选项框：取消 / 继续并加 `--accept-rbac-loss`）。
- 备份之后写入的数据无法找回；若需要，必须在恢复前由业务自行导出。
- 外部 etcd/对象存储/MQ、rocksmq existingClaim 的实例不支持一键恢复，预检会 FAIL，需要人工按 milvus-backup 文档处理。
- 恢复会 load 所有恢复出的集合；原来未 load 的集合需要业务自行 release。
- 本地导出副本（run_dir/backup_export）和 MinIO 中的备份不会自动删除，确认无误后由人工清理（会占用 master 磁盘）。
- `create milvuses` 权限在 RBAC 中无法按名字限制（K8s 限制），隔离自检仍会确认 SA 不能删除/修改其他 CR。

## 附录：已验证的坑

1. **3.0 必须以 root 运行**：2.6 写入的 rocksmq 和缓存文件属主是 root，而 3.0 镜像默认是非 root，会 CrashLoop。operator 1.3.12 的 `components.securityContext` 是容器级字段，fsGroup 会被静默忽略；`runAsNonRoot: true`（uid 1000）会报 `/milvus/configs: Permission denied`；`runAsUser: 0` 可以正常运行。如果策略不允许 root，需要管理员先 chown PVC 内的文件。这是本 skill 与官方文档（只 patch `spec.components.image`）唯一的行为差异，预检输出（`run_as_root`）和风险提示都会说明。
2. **NodePort 漂移**：Service 在 CR 之外（例如 KubeSphere 控制台，managedFields 中的 manager 是 `Mozilla`）被改成 NodePort，而 CR 仍是 ClusterIP 时，升级时的 reconcile 会把它改回 ClusterIP，再改成 NodePort 就会分配新端口。所以必须把 serviceType 写进 CR（standalone 写 `standalone`，cluster 写 `proxy`）。operator 1.3.x 没有填 nodePort 数值的字段，但 CR 为 NodePort 时会保留 Service 上已有的端口。Service 被删除重建后也会换端口，可用 `kubectl patch svc` 改回。
3. 依赖 deletionPolicy 为 Retain 时，删除 CR 不会删除 `<CR>-etcd` 和 `<CR>-minio` 两个 helm release 及其 PVC，所以恢复脚本删除前先把 deletionPolicy 改为 Delete 并开启 pvcDeletion。
4. milvus-backup 的配置要以 `<CR>` ConfigMap 中的 user.yaml 为准（bucket、`minio.rootPath`，缺省为 `files`、`etcd.rootPath`、`chanNamePrefix`）。CR 里 storage 下的 chart 值（如 bucketName、rootPath）不是 Milvus 的实际配置。
5. 经 port-forward 连 etcd 时不要用本地 2379，因为 master 自身的 etcd 在监听这个端口。create 时出现的 "etcd client is not initialized" 可以忽略。0.6.1 的 `get` 返回的 `state_code` 为 0，不能据此判断失败；以 create 输出中的 success、list 能列出、MinIO 对象数大于 0 为准。
6. milvus-backup restore 的目标是 3.0.x 时经 port-forward 曾卡住（bulk import）；恢复到 2.6.25 时经 port-forward 实测正常（`restore --rebuild_index`，5000 行约 18 秒）。目标 3.x 时要放在集群内运行。
7. 不要在 paused 状态下改镜像。
8. API Server 的 Forbidden 报错有两种写法：`Error from server (Forbidden)` 和 `... is forbidden`，判断时要忽略大小写。
9. 远端 `nohup … &` 如果接在 `&&` 链后面，会把整条链放到后台，ssh 会一直挂到脚本结束。所以 nohup 要单独作为一条命令。
10. **port-forward 必须直接后台运行 kubectl**：`ksa … port-forward &` 这类经 shell 函数的写法，`$!` 拿到的是子 shell 的 PID，kill 它不会结束 kubectl，port-forward 进程会残留并占住本地端口。脚本里直接 `kubectl --kubeconfig <SA> … &`，清理时再按 kubeconfig 路径 pkill 兜底。
11. 脚本使用 `set -euo pipefail`：`x=$(cond && echo y)` 在条件为假时赋值语句返回非 0，会让脚本无提示退出（rc=1）。可能为假的命令替换要加 `|| true`。脚本设置了 ERR trap，失败时日志会打印 `ERROR: 第 N 行命令失败`，排查 rc=1 时先找这一行。
12. 恢复脚本在发现 CR 后、预检前就需要读 Service/Pod/PVC/ConfigMap，所以先授予与升级相同的阶段 2 只读+patch 权限，删除/创建类权限在隔离自检前才追加。
