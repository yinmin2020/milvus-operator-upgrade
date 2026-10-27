# Install

## Recommended (skills CLI)

```bash
npx skills@latest add yinmin2020/milvus-operator-upgrade --skill milvus-operator-upgrade -g
```

Replace `milvus-operator-upgrade` with the published GitHub repository name.

You do **not** need to publish this repository to npm. The `skills` package on npm is only the installer.

## Verify

```bash
npx skills@latest list
ls ~/.agents/skills/milvus-operator-upgrade/SKILL.md
# or your agent-specific skills directory
```

## Update

```bash
npx skills@latest update
```
