#!/usr/bin/env zsh

emulate -L zsh
set -euo pipefail

TOOL_NAME="codex-ssh-manager"
REPO_RAW_BASE="${CODEX_SSH_REPO_RAW_BASE:-https://raw.githubusercontent.com/leezhuuuuu/codex-ssh/main}"
INSTALL_DIR="${CODEX_SSH_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_PATH="$INSTALL_DIR/$TOOL_NAME"
SOURCE_URL="$REPO_RAW_BASE/scripts/codex-ssh-manager.zsh"

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

main() {
  local tmp
  tmp="$(mktemp)"

  info "下载 Codex SSH Manager"
  download "$SOURCE_URL" "$tmp"

  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"

  ok "已安装到：$INSTALL_PATH"

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
