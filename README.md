# Codex SSH Manager

一个 macOS 上使用的中文交互式 SSH 主机管理向导。它面向通用 SSH 主机，不限定 Debian；Codex App 远程连接只是其中一个检查场景。

## 功能

- 添加新的 SSH Host 到 `~/.ssh/config`
- 生成新 ed25519 密钥，或选择复用已有私钥
- 上传公钥到远程服务器
- 查看本工具管理的 Host 和现有 SSH config Host
- 启动菜单顶部展示当前私钥，以及这些私钥在 SSH config 中对应的机器
- 测试 SSH 免交互连接
- 更新、禁用或删除本工具创建的 Host 配置块
- 检查远程主机是否已准备好供 Codex App 使用

## 使用

一键安装并启动：

```bash
/bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/leezhuuuuu/codex-ssh/main/scripts/install.sh)"
```

安装后默认命令位置：

```text
~/.local/bin/codex-ssh-manager
```

如果 `~/.local/bin` 已经在 `PATH` 中，后续可以直接运行：

```bash
codex-ssh-manager
```

本地源码运行：

```bash
chmod +x scripts/codex-ssh-manager.zsh
./scripts/codex-ssh-manager.zsh
```

打开菜单后，优先选择：

```text
1. 添加 SSH 主机
```

按提示输入 Host 别名、服务器 IP/域名、用户名和端口。到私钥步骤时，可以选择默认新建、从已有私钥列表选择，或手动输入路径。脚本会在修改 `~/.ssh/config` 前自动备份。

添加完成后，可以选择：

```text
7. 检查 Codex App 远程连接准备情况
```

确认远程机器上是否能找到 `codex` 命令。

## 安全测试

如果你想先演练，不碰真实的 `~/.ssh/config`，可以使用临时配置：

```bash
tmpdir="$(mktemp -d)"
CODEX_SSH_HOME="$tmpdir/state" \
CODEX_SSH_CONFIG="$tmpdir/config" \
CODEX_SSH_DIR="$tmpdir/ssh" \
./scripts/codex-ssh-manager.zsh
```

这样脚本只会改临时目录里的文件。

## Codex App 远程连接条件

Codex App 使用 SSH Host 时，需要满足：

- 本机 `~/.ssh/config` 里有具体的 `Host` 别名
- 本机执行 `ssh <host-alias>` 可以成功
- 远程主机已安装并登录 `codex`
- 远程登录 shell 的 `PATH` 里可以找到 `codex`

然后在 Codex App 中进入：

```text
Settings → Connections → SSH host
```

添加或启用对应 Host，并选择远程项目目录。
