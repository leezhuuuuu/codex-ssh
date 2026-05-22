# Codex SSH Manager

一个面向 macOS 的中文交互式 SSH 主机管理向导，用来帮你把本机、远程服务器和 Codex App 的 SSH 远程连接配置串起来。

只要目标机器支持 OpenSSH，就可以用它管理 SSH Host、密钥、公钥登录、远程 Codex CLI 安装检查和远程登录。

## 适合谁

- 想让 Codex App 通过 SSH 连接远程服务器
- 现在还能用密码 SSH，但想改成密钥登录
- 不熟悉 `~/.ssh/config`、`authorized_keys`、`IdentityFile`
- 远程 `codex login` 遇到 `localhost:1455` 回调问题
- 远程机器装了 Codex CLI，但 `codex: command not found`

## 一键安装

在 macOS 终端执行下面这条命令即可安装并启动向导：

```bash
curl -fsSL https://codex-ssh.leezhu.cn/install | zsh
```

安装脚本会下载最新源码包，并覆盖安装到：

```text
~/.local/bin/codex-ssh-manager
```

如果你本机代理导致域名访问异常，可以临时绕过代理再安装：

```bash
env -u https_proxy -u http_proxy -u all_proxy -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
curl -fsSL https://codex-ssh.leezhu.cn/install | zsh
```

也可以不用自定义域名，直接使用 GitHub 源码包安装：

```bash
/bin/zsh -c 'tmpdir="$(mktemp -d)" && curl -fsSL https://codeload.github.com/leezhuuuuu/codex-ssh/tar.gz/refs/heads/main | tar -xz -C "$tmpdir" && /bin/zsh "$tmpdir"/codex-ssh-main/scripts/install.sh'
```

如果 `~/.local/bin` 已经在 `PATH` 中，后续直接运行：

```bash
codex-ssh-manager
```

再次执行一键安装命令会重新下载最新源码包，并覆盖更新本机命令。

## 快速流程

### 1. 添加 SSH 主机

运行：

```bash
codex-ssh-manager
```

选择：

```text
1. 添加 SSH 主机
```

按提示输入：

- Host 别名，例如 `my-server`
- 服务器 IP 或域名
- SSH 用户名
- SSH 端口，默认 `22`
- 私钥：可以新建，也可以选择已有私钥

脚本会帮助你生成或选择密钥、上传公钥、备份并写入 `~/.ssh/config`。

### 2. 检查 Codex App 远程连接准备情况

选择：

```text
7. 检查 Codex App 远程连接准备情况
```

它会用彩色状态摘要检查：

- SSH 是否能免密连接
- 远程系统信息
- Node.js / npm 是否存在
- 远程 `codex` 是否可用
- Codex standalone 是否已安装但 `PATH` 没配好

如果远程没有 Codex CLI，脚本会给出手动安装命令，也可以在你确认后自动尝试安装。

### 3. 登录远程 Codex CLI

选择：

```text
8. 登录远程 Codex CLI
```

有两种方式：

```text
1. 浏览器登录，自动转发 localhost:1455
2. Device Auth 登录，不需要端口转发
```

浏览器登录会自动建立：

```text
本机 localhost:1455 -> 远程 127.0.0.1:1455
```

这样远程 `codex login` 的 OAuth 回调可以通过 SSH 隧道回到远端登录服务。脚本只会显示登录 URL，不会自动打开浏览器；你可以复制到自己选择的浏览器中打开。

登录完成后，回到 Codex App：

```text
Settings -> Connections -> SSH host
```

添加或启用对应 Host，并选择远程项目目录。

## 菜单说明

```text
1. 添加 SSH 主机
2. 查看 SSH 主机
3. 测试 SSH 连接
4. 上传/修复公钥登录
5. 更新 SSH Host 配置
6. 禁用或删除 Host
7. 检查 Codex App 远程连接准备情况
8. 登录远程 Codex CLI
9. 诊断连接问题
10. 退出
```

启动菜单顶部会显示当前发现的私钥，以及这些私钥在 `~/.ssh/config` 中对应的机器。

## Codex App 远程连接条件

Codex App 使用 SSH Host 前，需要满足：

- 本机 `~/.ssh/config` 中有具体的 `Host` 别名
- 本机执行 `ssh <host-alias>` 可以成功
- 远程主机已安装 Codex CLI
- 远程 Codex CLI 已登录
- 远程登录 shell 的 `PATH` 能找到 `codex`

这个工具会尽量帮你检查和修复以上条件。

## 常见问题

### 远程 `codex login` 提示 localhost:1455 回调失败

使用菜单：

```text
8. 登录远程 Codex CLI -> 1. 浏览器登录，自动转发 localhost:1455
```

脚本会在登录期间保持 SSH 隧道，登录完成或中断后自动关闭。

### 登录时报 `Country, region, or territory not supported`

这通常不是端口转发问题，而是远程服务器访问 OpenAI token endpoint 时被地区或网络策略拒绝。

在远程机器上检查：

```bash
curl https://ipinfo.io/json
curl -I https://auth.openai.com
curl -I https://api.openai.com
```

需要让远程服务器的出口网络位于 OpenAI 支持的地区，并能正常访问 OpenAI 服务。

### 远程已安装，但 SSH 进去后 `codex: command not found`

Codex standalone 可能安装到了：

```text
~/.local/bin/codex
~/.codex/packages/standalone/current/codex
```

但远程 shell 的 `PATH` 没有 `~/.local/bin`。菜单 `7` 会检测这个情况，并可在你确认后写入：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

到远程：

```text
~/.bashrc
~/.profile
```

## 安全测试

如果你想先演练，不碰真实的 `~/.ssh/config`：

```bash
tmpdir="$(mktemp -d)"
CODEX_SSH_HOME="$tmpdir/state" \
CODEX_SSH_CONFIG="$tmpdir/config" \
CODEX_SSH_DIR="$tmpdir/ssh" \
./scripts/codex-ssh-manager.zsh
```

这样脚本只会修改临时目录中的文件。

## 本地开发运行

```bash
chmod +x scripts/codex-ssh-manager.zsh
./scripts/codex-ssh-manager.zsh
```

安装脚本：

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```
