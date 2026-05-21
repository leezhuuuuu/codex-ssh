#!/usr/bin/env zsh

emulate -L zsh
set -euo pipefail

TOOL_NAME="codex-ssh-manager"
REPO_ARCHIVE_URL="${CODEX_SSH_REPO_ARCHIVE_URL:-https://codeload.github.com/leezhuuuuu/codex-ssh/tar.gz/refs/heads/main}"
MANAGER_SOURCE_PATH="scripts/codex-ssh-manager.zsh"
INSTALL_DIR="${CODEX_SSH_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_PATH="$INSTALL_DIR/$TOOL_NAME"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
else
  C_RESET=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

say() { print -r -- "$*"; }
info() { say "${C_BLUE}==>${C_RESET} $*"; }
ok() { say "${C_GREEN}✓${C_RESET} $*"; }
warn() { say "${C_YELLOW}!${C_RESET} $*"; }

download() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  else
    say "需要 curl 或 wget 才能下载安装脚本。" >&2
    return 1
  fi
}

download_manager() {
  local output="$1"
  local tmpdir archive manager

  if [[ -n "${CODEX_SSH_MANAGER_URL:-}" ]]; then
    download "$CODEX_SSH_MANAGER_URL" "$output"
    return 0
  fi

  tmpdir="$(mktemp -d)"
  archive="$tmpdir/codex-ssh.tar.gz"

  download "$REPO_ARCHIVE_URL" "$archive"
  tar -xzf "$archive" -C "$tmpdir"

  manager="$(find "$tmpdir" -path "*/$MANAGER_SOURCE_PATH" -type f -print -quit)"
  if [[ -z "$manager" ]]; then
    say "源码包中未找到 $MANAGER_SOURCE_PATH。" >&2
    return 1
  fi

  cp "$manager" "$output"
  rm -rf "$tmpdir"
}

main() {
  local tmp
  tmp="$(mktemp)"

  info "下载 Codex SSH Manager 最新源码包"
  download_manager "$tmp"

  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"

  ok "已覆盖安装到：$INSTALL_PATH"

  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "$INSTALL_DIR 还不在当前 PATH 中。"
    say "你可以直接运行：$INSTALL_PATH"
    say "也可以把下面这一行加入 ~/.zshrc："
    say "export PATH=\"$INSTALL_DIR:\$PATH\""
  else
    say "以后可直接运行：$TOOL_NAME"
  fi

  say ""
  info "启动管理向导"
  exec "$INSTALL_PATH"
}

main "$@"
