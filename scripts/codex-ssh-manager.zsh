#!/usr/bin/env zsh

emulate -L zsh
set -o pipefail

TOOL_NAME="Codex SSH / 通用 SSH 主机管理向导"
SCRIPT_PATH="${(%):-%N}"
STATE_DIR="${CODEX_SSH_HOME:-$HOME/.codex-ssh}"
REGISTRY_FILE="$STATE_DIR/hosts.tsv"
BACKUP_DIR="$STATE_DIR/backups"
SSH_CONFIG="${CODEX_SSH_CONFIG:-$HOME/.ssh/config}"
SSH_DIR="${CODEX_SSH_DIR:-$HOME/.ssh}"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_CYAN="$(tput setaf 6)"
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
fi

say() { print -r -- "$*"; }
info() { say "${C_BLUE}==>${C_RESET} $*"; }
ok() { say "${C_GREEN}✓${C_RESET} $*"; }
warn() { say "${C_YELLOW}!${C_RESET} $*"; }
err() { say "${C_RED}✗${C_RESET} $*" >&2; }
dim() { say "${C_DIM}$*${C_RESET}"; }

status_item() {
  local state="$1" title="$2" value="${3:-}" detail="${4:-}"
  local marker label color
  case "$state" in
    ok)
      marker="✓"; label="正常"; color="$C_GREEN"
      ;;
    warn)
      marker="!"; label="需处理"; color="$C_YELLOW"
      ;;
    bad)
      marker="✗"; label="失败"; color="$C_RED"
      ;;
    *)
      marker="-"; label="信息"; color="$C_BLUE"
      ;;
  esac

  if [[ -n "$value" ]]; then
    say "  ${color}${marker} [$label]${C_RESET} ${C_BOLD}${title}${C_RESET}: $value"
  else
    say "  ${color}${marker} [$label]${C_RESET} ${C_BOLD}${title}${C_RESET}"
  fi
  [[ -n "$detail" ]] && dim "      $detail"
}

command_hint() {
  say "    ${C_CYAN}$*${C_RESET}"
}

url_hint() {
  say "    ${C_BOLD}${C_CYAN}$*${C_RESET}"
}

pause() {
  print -n -- "${C_DIM}按回车继续...${C_RESET}"
  read -r _
}

prompt() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    print -n -- "${C_CYAN}?${C_RESET} $label ${C_DIM}[$default]${C_RESET}: "
  else
    print -n -- "${C_CYAN}?${C_RESET} $label: "
  fi
  read -r value
  if [[ -z "$value" && -n "$default" ]]; then
    value="$default"
  fi
  REPLY="$value"
}

confirm() {
  local label="$1"
  local default="${2:-n}"
  local hint answer
  if [[ "$default" == "y" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi
  while true; do
    print -n -- "${C_CYAN}?${C_RESET} $label ${C_DIM}[$hint]${C_RESET}: "
    read -r answer
    [[ -z "$answer" ]] && answer="$default"
    case "${answer:l}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

ensure_files() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$SSH_DIR"
  chmod 700 "$SSH_DIR" 2>/dev/null || true
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    print -r -- "# alias	hostname	user	port	identity	status	created_at	updated_at" > "$REGISTRY_FILE"
  fi
  if [[ ! -f "$SSH_CONFIG" ]]; then
    touch "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG" 2>/dev/null || true
  fi
}

timestamp() {
  date "+%Y%m%d-%H%M%S"
}

backup_config() {
  ensure_files
  local backup="$BACKUP_DIR/config.$(timestamp).bak"
  cp "$SSH_CONFIG" "$backup"
  ok "已备份 SSH config：$backup"
}

validate_alias() {
  local alias="$1"
  if [[ -z "$alias" ]]; then
    err "Host 别名不能为空。"
    return 1
  fi
  if [[ "$alias" == *[[:space:]]* || "$alias" == *"*"* || "$alias" == *"?"* || "$alias" == *"!"* ]]; then
    err "Host 别名不能包含空格、*、?、!。Codex App 需要具体 Host 别名。"
    return 1
  fi
  return 0
}

safe_alias() {
  local alias="$1"
  print -r -- "${alias//[^A-Za-z0-9._-]/_}"
}

host_exists_in_config() {
  local alias="$1"
  awk -v target="$alias" '
    BEGIN { found=0 }
    /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
      for (i=2; i<=NF; i++) if ($i == target) found=1
    }
    END { exit found ? 0 : 1 }
  ' "$SSH_CONFIG"
}

is_managed_host() {
  local alias="$1"
  grep -Fq "# BEGIN CODEX_SSH_MANAGER host=$alias" "$SSH_CONFIG"
}

registry_line() {
  local alias="$1"
  awk -F '\t' -v target="$alias" 'NF && $1 !~ /^#/ && $1 == target { print; exit }' "$REGISTRY_FILE"
}

upsert_registry() {
  local alias="$1" hostname="$2" user="$3" port="$4" identity="$5" host_status="${6:-enabled}"
  local now created tmp
  now="$(date "+%Y-%m-%dT%H:%M:%S%z")"
  created="$now"
  local existing
  existing="$(registry_line "$alias")"
  if [[ -n "$existing" ]]; then
    created="$(print -r -- "$existing" | awk -F '\t' '{ print $7 }')"
  fi
  tmp="$(mktemp)"
  awk -F '\t' -v OFS='\t' -v target="$alias" '
    $1 == target && $1 !~ /^#/ { next }
    { print }
  ' "$REGISTRY_FILE" > "$tmp"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$alias" "$hostname" "$user" "$port" "$identity" "$host_status" "$created" "$now" >> "$tmp"
  mv "$tmp" "$REGISTRY_FILE"
}

mark_registry_status() {
  local alias="$1" host_status="$2" tmp now
  now="$(date "+%Y-%m-%dT%H:%M:%S%z")"
  tmp="$(mktemp)"
  awk -F '\t' -v OFS='\t' -v target="$alias" -v host_status="$host_status" -v now="$now" '
    $1 == target && $1 !~ /^#/ { $6=host_status; $8=now; print; next }
    { print }
  ' "$REGISTRY_FILE" > "$tmp"
  mv "$tmp" "$REGISTRY_FILE"
}

render_host_block() {
  local alias="$1" hostname="$2" user="$3" port="$4" identity="$5"
  print -r -- "# BEGIN CODEX_SSH_MANAGER host=$alias"
  print -r -- "Host $alias"
  print -r -- "    HostName $hostname"
  print -r -- "    User $user"
  print -r -- "    Port $port"
  print -r -- "    IdentityFile $identity"
  print -r -- "    IdentitiesOnly yes"
  print -r -- "# END CODEX_SSH_MANAGER host=$alias"
}

remove_managed_block() {
  local alias="$1" tmp
  tmp="$(mktemp)"
  awk -v alias="$alias" '
    $0 == "# BEGIN CODEX_SSH_MANAGER host=" alias { skip=1; next }
    $0 == "# END CODEX_SSH_MANAGER host=" alias { skip=0; next }
    skip != 1 { print }
  ' "$SSH_CONFIG" > "$tmp"
  mv "$tmp" "$SSH_CONFIG"
}

write_managed_host() {
  local alias="$1" hostname="$2" user="$3" port="$4" identity="$5"
  backup_config
  if is_managed_host "$alias"; then
    remove_managed_block "$alias"
  fi
  {
    print -r -- ""
    render_host_block "$alias" "$hostname" "$user" "$port" "$identity"
  } >> "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG" 2>/dev/null || true
  upsert_registry "$alias" "$hostname" "$user" "$port" "$identity" "enabled"
  ok "已写入 Host $alias 到 $SSH_CONFIG"
}

list_config_hosts() {
  awk '
    /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
      for (i=2; i<=NF; i++) {
        if ($i !~ /[*?!]/) print $i
      }
    }
  ' "$SSH_CONFIG" | sort -u
}

list_managed_hosts() {
  awk -F '\t' '$1 !~ /^#/ && NF >= 8 { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' "$REGISTRY_FILE" | sort
}

choose_host() {
  local only_managed="${1:-no}"
  local hosts=()
  local line alias
  if [[ "$only_managed" == "yes" ]]; then
    while IFS=$'\t' read -r alias _; do
      [[ -n "$alias" ]] && hosts+=("$alias")
    done < <(list_managed_hosts)
  else
    while IFS= read -r alias; do
      [[ -n "$alias" ]] && hosts+=("$alias")
    done < <(list_config_hosts)
  fi

  if (( ${#hosts[@]} == 0 )); then
    warn "还没有可选择的 Host。"
    return 1
  fi

  say ""
  info "请选择 Host："
  local i
  for i in {1..${#hosts[@]}}; do
    say "  $i. ${hosts[$i]}"
  done
  while true; do
    prompt "输入序号"
    if [[ "$REPLY" == <-> && "$REPLY" -ge 1 && "$REPLY" -le ${#hosts[@]} ]]; then
      CHOSEN_HOST="${hosts[$REPLY]}"
      return 0
    fi
    warn "请输入 1-${#hosts[@]} 之间的数字。"
  done
}

normalize_path() {
  local path="$1"
  print -r -- "${path/#\~/$HOME}"
}

looks_like_private_key() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  case "${file:t}" in
    *.pub|config|known_hosts|known_hosts.old|authorized_keys|allowed_signers)
      return 1
      ;;
  esac
  local first_line
  first_line="$(head -n 1 "$file" 2>/dev/null || true)"
  [[ "$first_line" == "-----BEGIN "*PRIVATE\ KEY"-----" ]]
}

list_identity_candidates() {
  local candidates=()
  local file identity

  if [[ -d "$SSH_DIR" ]]; then
    for file in "$SSH_DIR"/*(N); do
      looks_like_private_key "$file" && candidates+=("$file")
    done
  fi

  if [[ -f "$SSH_CONFIG" ]]; then
    while IFS= read -r identity; do
      identity="$(normalize_path "$identity")"
      [[ -n "$identity" && -f "$identity" ]] && candidates+=("$identity")
    done < <(awk '
      /^[[:space:]]*[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee][[:space:]]+/ { print $2 }
    ' "$SSH_CONFIG")
  fi

  if (( ${#candidates[@]} > 0 )); then
    printf "%s\n" "${(@u)candidates}" | sort
  fi
}

list_config_identity_usage() {
  awk -v home="$HOME" '
    function expand(path) {
      gsub(/^"|"$/, "", path)
      if (path == "") return ""
      if (path == "~") return home
      if (path ~ /^\//) return path
      if (path ~ /^~\//) {
        sub(/^~/, home, path)
        return path
      }
      return path
    }
    function reset_block() {
      hosts=""
      hostname=""
      user=""
      port=""
      identity=""
    }
    function flush_block(    n, parts, i, host, target, label) {
      if (hosts == "" || identity == "") return
      n=split(hosts, parts, " ")
      for (i=1; i<=n; i++) {
        host=parts[i]
        if (host == "" || host ~ /[*?!]/) continue
        target=(hostname != "" ? hostname : host)
        label=host " (" (user != "" ? user "@" : "") target (port != "" ? ":" port : "") ")"
        print expand(identity) "\t" label
      }
    }
    BEGIN { reset_block() }
    /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
      flush_block()
      reset_block()
      for (i=2; i<=NF; i++) hosts = hosts (hosts == "" ? "" : " ") $i
      next
    }
    /^[[:space:]]*[Hh][Oo][Ss][Tt][Nn][Aa][Mm][Ee][[:space:]]+/ { hostname=$2; next }
    /^[[:space:]]*[Uu][Ss][Ee][Rr][[:space:]]+/ { user=$2; next }
    /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+/ { port=$2; next }
    /^[[:space:]]*[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee][[:space:]]+/ { identity=$2; next }
    END { flush_block() }
  ' "$SSH_CONFIG"
}

print_key_dashboard() {
  local keys=()
  local key usage_key usage_label labels

  while IFS= read -r key; do
    [[ -n "$key" ]] && keys+=("$key")
  done < <(list_identity_candidates)

  if (( ${#keys[@]} == 0 )); then
    info "当前 SSH 私钥"
    dim "未在 $SSH_DIR 或 $SSH_CONFIG 中发现可识别的私钥。"
    say ""
    return 0
  fi

  info "当前 SSH 私钥与对应机器"
  for key in "${keys[@]}"; do
    say "  ${C_CYAN}${key}${C_RESET}"
    labels=()
    while IFS=$'\t' read -r usage_key usage_label; do
      [[ "$usage_key" == "$key" && -n "$usage_label" ]] && labels+=("$usage_label")
    done < <(list_config_identity_usage)

    if (( ${#labels[@]} == 0 )); then
      dim "    - 未绑定到 ~/.ssh/config 中的具体 Host"
    else
      for usage_label in "${(@u)labels}"; do
        say "    - $usage_label"
      done
    fi
  done
  say ""
}

choose_identity_file() {
  local alias="$1"
  local default_identity="$2"
  local candidates=()
  local item

  while IFS= read -r item; do
    [[ -n "$item" ]] && candidates+=("$item")
  done < <(list_identity_candidates)

  say ""
  info "选择 SSH 私钥"
  say "1. 使用默认路径，必要时自动生成新密钥"
  say "   ${C_DIM}$default_identity${C_RESET}"
  if (( ${#candidates[@]} > 0 )); then
    say "2. 从已有私钥列表选择"
  else
    say "2. 从已有私钥列表选择 ${C_DIM}(未发现可选私钥)${C_RESET}"
  fi
  say "3. 手动输入私钥路径"

  while true; do
    prompt "请选择" "1"
    case "$REPLY" in
      1)
        CHOSEN_IDENTITY="$default_identity"
        return 0
        ;;
      2)
        if (( ${#candidates[@]} == 0 )); then
          warn "没有在 $SSH_DIR 或 $SSH_CONFIG 中发现已有私钥。"
          continue
        fi
        say ""
        info "已有私钥"
        local i
        for i in {1..${#candidates[@]}}; do
          say "  $i. ${candidates[$i]}"
        done
        while true; do
          prompt "输入序号"
          if [[ "$REPLY" == <-> && "$REPLY" -ge 1 && "$REPLY" -le ${#candidates[@]} ]]; then
            CHOSEN_IDENTITY="${candidates[$REPLY]}"
            return 0
          fi
          warn "请输入 1-${#candidates[@]} 之间的数字。"
        done
        ;;
      3)
        prompt "私钥文件路径" "$default_identity"
        CHOSEN_IDENTITY="$(normalize_path "$REPLY")"
        return 0
        ;;
      *)
        warn "请输入 1、2 或 3。"
        ;;
    esac
  done
}

ensure_key_pair() {
  local alias="$1" identity="$2"
  local pub="${identity}.pub"
  if [[ -f "$identity" && -f "$pub" ]]; then
    ok "检测到密钥：$identity"
    return 0
  fi
  if [[ -e "$identity" && ! -f "$pub" ]]; then
    warn "私钥存在但公钥不存在：$pub"
    if confirm "是否从私钥重新生成公钥？" "y"; then
      ssh-keygen -y -f "$identity" > "$pub" || return 1
      chmod 644 "$pub" 2>/dev/null || true
      ok "已生成公钥：$pub"
      return 0
    fi
    return 1
  fi
  info "将为 Host $alias 生成 ed25519 密钥。"
  dim "私钥会保留在本机：$identity"
  if confirm "生成新密钥时是否不设置 passphrase？Codex App 使用起来会更顺手" "y"; then
    ssh-keygen -t ed25519 -f "$identity" -C "codex-ssh-manager-$alias" -N "" || return 1
  else
    ssh-keygen -t ed25519 -f "$identity" -C "codex-ssh-manager-$alias" || return 1
  fi
  chmod 600 "$identity" 2>/dev/null || true
  chmod 644 "$pub" 2>/dev/null || true
  ok "已生成密钥：$identity"
}

upload_public_key_to_target() {
  local identity="$1" user="$2" hostname="$3" port="$4"
  local pub="${identity}.pub"
  if [[ ! -f "$pub" ]]; then
    err "找不到公钥文件：$pub"
    return 1
  fi

  info "准备上传公钥到 $user@$hostname:$port"
  warn "这一步可能会要求输入服务器当前的 SSH 密码。"
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -p "$port" -i "$pub" "$user@$hostname"
  else
    warn "未找到 ssh-copy-id，改用兼容方式上传。"
    ssh -p "$port" "$user@$hostname" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < "$pub"
  fi
}

test_ssh_alias() {
  local alias="$1"
  info "测试 SSH 免密连接"
  dim "ssh -F $SSH_CONFIG -o BatchMode=yes $alias true"
  if ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=8 "$alias" true; then
    status_item ok "SSH" "$alias 可连接" "本机已经可以通过 ~/.ssh/config 中的 Host 别名连接。"
    return 0
  fi
  status_item bad "SSH" "$alias 免密连接失败" "Codex App 也会连接失败；可先运行诊断或重新上传公钥。"
  warn "诊断命令：ssh -F $SSH_CONFIG -v $alias"
  return 1
}

test_ssh_password_target() {
  local user="$1" hostname="$2" port="$3"
  info "测试基础 SSH 连通性：ssh -p $port $user@$hostname true"
  warn "这一步可能会要求输入服务器密码。"
  ssh -p "$port" -o ConnectTimeout=8 "$user@$hostname" true
}

extract_managed_field() {
  local alias="$1" field="$2"
  local idx
  case "$field" in
    hostname) idx=2 ;;
    user) idx=3 ;;
    port) idx=4 ;;
    identity) idx=5 ;;
    status) idx=6 ;;
    *) return 1 ;;
  esac
  registry_line "$alias" | awk -F '\t' -v idx="$idx" '{ print $idx }'
}

kv_get() {
  local text="$1" key="$2"
  print -r -- "$text" | awk -F '=' -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

remote_codex_probe() {
  local alias="$1"
  ssh -F "$SSH_CONFIG" "$alias" 'sh -s' <<'REMOTE_PROBE'
codex_path="$(command -v codex 2>/dev/null || true)"
local_bin="$HOME/.local/bin"
local_codex="$local_bin/codex"
standalone_codex="$HOME/.codex/packages/standalone/current/codex"

printf "path=%s\n" "$PATH"
printf "home=%s\n" "$HOME"
printf "local_bin=%s\n" "$local_bin"
printf "codex_path=%s\n" "$codex_path"
printf "local_codex=%s\n" "$local_codex"
printf "standalone_codex=%s\n" "$standalone_codex"

if [ -n "$codex_path" ]; then
  printf "codex_status=path\n"
  printf "codex_runnable=%s\n" "$codex_path"
  printf "codex_version=%s\n" "$(codex --version 2>/dev/null || true)"
elif [ -x "$local_codex" ]; then
  printf "codex_status=installed_not_in_path\n"
  printf "codex_runnable=%s\n" "$local_codex"
  printf "codex_version=%s\n" "$("$local_codex" --version 2>/dev/null || true)"
elif [ -x "$standalone_codex" ]; then
  printf "codex_status=installed_not_in_path\n"
  printf "codex_runnable=%s\n" "$standalone_codex"
  printf "codex_version=%s\n" "$("$standalone_codex" --version 2>/dev/null || true)"
else
  printf "codex_status=missing\n"
  printf "codex_runnable=\n"
  printf "codex_version=\n"
fi
REMOTE_PROBE
}

remote_fix_codex_path() {
  local alias="$1"
  ssh -F "$SSH_CONFIG" "$alias" 'sh -s' <<'REMOTE_FIX_PATH'
set -eu
line='export PATH="$HOME/.local/bin:$PATH"'
changed=0
for file in "$HOME/.bashrc" "$HOME/.profile"; do
  touch "$file"
  if ! grep -Fq "$line" "$file"; then
    printf "\n# Added by codex-ssh-manager so codex standalone is available in interactive shells\n%s\n" "$line" >> "$file"
    changed=1
  fi
done
printf "PATH_FIX_CHANGED=%s\n" "$changed"
REMOTE_FIX_PATH
}

local_port_is_free() {
  local port="$1"
  if command -v nc >/dev/null 2>&1; then
    ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  return 0
}

print_manual_codex_install_commands() {
  local alias="$1" kernel="$2" os_id="$3" os_like="$4"

  if [[ "$os_id $os_like" == *debian* || "$os_id $os_like" == *ubuntu* ]]; then
    say "在远程主机上执行："
    command_hint "sudo apt update && sudo apt install -y nodejs npm"
    command_hint "sudo npm i -g @openai/codex"
  elif [[ "$os_id $os_like" == *fedora* || "$os_id $os_like" == *rhel* || "$os_id $os_like" == *centos* ]]; then
    say "在远程主机上执行："
    command_hint "sudo dnf install -y nodejs npm"
    command_hint "sudo npm i -g @openai/codex"
  elif [[ "$os_id $os_like" == *arch* ]]; then
    say "在远程主机上执行："
    command_hint "sudo pacman -S nodejs npm"
    command_hint "sudo npm i -g @openai/codex"
  elif [[ "$kernel" == "Darwin" ]]; then
    say "在远程主机上执行："
    command_hint "brew install node"
    command_hint "npm i -g @openai/codex"
  else
    say "远程系统未匹配到内置安装方案，请先安装 Node.js/npm，再执行："
    command_hint "npm i -g @openai/codex"
  fi
  say ""
  say "安装后继续执行："
  command_hint "ssh $alias"
  command_hint "codex"
  dim "首次运行 codex 需要在远程完成登录。登录完成后，回到本菜单再次选择 7 检查。"
}

handle_codex_path_fix_prompt() {
  local alias="$1" local_bin="$2"
  say ""
  status_item warn "PATH 修复" "Codex 已安装但 PATH 缺少 $local_bin" "写入 ~/.bashrc 和 ~/.profile 后，新开的远程 shell 就能直接运行 codex。"
  if confirm "是否自动把 $local_bin 加入远程 PATH？" "y"; then
    local fix_output
    if fix_output="$(remote_fix_codex_path "$alias" 2>&1)"; then
      status_item ok "PATH 修复" "已写入远程 shell 配置" "请重新 ssh 登录，或执行：source ~/.bashrc"
      dim "$fix_output"
    else
      status_item bad "PATH 修复" "写入失败" "$fix_output"
    fi
  else
    warn "已跳过 PATH 修复。你可以手动执行："
    command_hint "echo 'export PATH=\"\\$HOME/.local/bin:\\$PATH\"' >> ~/.bashrc"
    command_hint "source ~/.bashrc"
  fi
}

remote_install_codex() {
  local alias="$1" kernel="$2" os_id="$3" os_like="$4"
  local log_file ssh_status install_status install_reason codex_path codex_path_status codex_version

  log_file="$(mktemp)"
  say ""
  info "自动安装 Codex CLI"
  warn "即将在远程主机执行包管理器和 npm 全局安装。"
  dim "自动安装仅支持 root 用户或免密码 sudo；如果远端需要输入 sudo 密码，会停止并给出手动命令。"
  dim "安装日志会实时显示，并临时保存到：$log_file"
  say ""

  ssh -F "$SSH_CONFIG" "$alias" 'sh -s' 2>&1 <<'REMOTE_INSTALL' | tee "$log_file"
log() {
  printf '%s\n' "[codex-install] $*"
}

fail() {
  printf '%s\n' "INSTALL_STATUS=failed"
  printf '%s\n' "INSTALL_REASON=$*"
  exit 1
}

run_sudo() {
  if [ -n "$SUDO_CMD" ]; then
    "$SUDO_CMD" "$@"
  else
    "$@"
  fi
}

if [ -r /etc/os-release ]; then
  . /etc/os-release
fi

KERNEL="$(uname -s 2>/dev/null || true)"
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"

if [ "$(id -u)" = "0" ]; then
  SUDO_CMD=""
elif command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    SUDO_CMD="sudo"
  else
    fail "当前用户需要输入 sudo 密码；自动安装无法安全接收密码。请 ssh 登录后按手动命令安装。"
  fi
else
  SUDO_CMD=""
fi

log "远程系统：${PRETTY_NAME:-$KERNEL}"
log "当前用户：$(id -un 2>/dev/null || true)"

if ! command -v npm >/dev/null 2>&1; then
  log "未找到 npm，尝试安装 Node.js/npm。"
  if command -v apt-get >/dev/null 2>&1; then
    run_sudo apt-get update || fail "apt-get update 失败。请检查 apt 源、网络或 sudo 权限。"
    run_sudo apt-get install -y nodejs npm || fail "apt-get 安装 nodejs/npm 失败。"
  elif command -v dnf >/dev/null 2>&1; then
    run_sudo dnf install -y nodejs npm || fail "dnf 安装 nodejs/npm 失败。"
  elif command -v yum >/dev/null 2>&1; then
    run_sudo yum install -y nodejs npm || fail "yum 安装 nodejs/npm 失败。"
  elif command -v pacman >/dev/null 2>&1; then
    run_sudo pacman -Sy --noconfirm nodejs npm || fail "pacman 安装 nodejs/npm 失败。"
  elif command -v apk >/dev/null 2>&1; then
    run_sudo apk add nodejs npm || fail "apk 安装 nodejs/npm 失败。"
  elif command -v zypper >/dev/null 2>&1; then
    run_sudo zypper --non-interactive install nodejs npm || fail "zypper 安装 nodejs/npm 失败。"
  elif [ "$KERNEL" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    brew install node || fail "brew 安装 node 失败。"
  else
    fail "未找到 npm，也未识别可用包管理器。请手动安装 Node.js/npm。"
  fi
else
  log "已找到 npm：$(command -v npm)"
fi

command -v npm >/dev/null 2>&1 || fail "安装后仍找不到 npm；请检查 PATH。"

log "安装 @openai/codex。"
if ! run_sudo npm i -g @openai/codex; then
  fail "npm 全局安装 @openai/codex 失败。常见原因：网络无法访问 npm、权限不足、Node/npm 版本过旧。"
fi

codex_path="$(command -v codex 2>/dev/null || true)"
codex_path_status="path"
if [ -z "$codex_path" ] && [ -x "$HOME/.local/bin/codex" ]; then
  codex_path="$HOME/.local/bin/codex"
  codex_path_status="installed_not_in_path"
fi
if [ -z "$codex_path" ] && [ -x "$HOME/.codex/packages/standalone/current/codex" ]; then
  codex_path="$HOME/.codex/packages/standalone/current/codex"
  codex_path_status="installed_not_in_path"
fi
if [ -z "$codex_path" ]; then
  fail "安装完成后仍无法找到 codex。请检查 npm 全局 bin 目录或 standalone 安装目录。"
fi

printf '%s\n' "INSTALL_STATUS=ok"
printf '%s\n' "CODEX_PATH=$codex_path"
printf '%s\n' "CODEX_PATH_STATUS=$codex_path_status"
printf '%s\n' "CODEX_VERSION=$("$codex_path" --version 2>/dev/null || true)"
REMOTE_INSTALL
  ssh_status=${pipestatus[1]}

  install_status="$(awk -F '=' '$1 == "INSTALL_STATUS" { print $2 }' "$log_file" | tail -1)"
  install_reason="$(awk -F '=' '$1 == "INSTALL_REASON" { sub(/^[^=]*=/, ""); print }' "$log_file" | tail -1)"
  codex_path="$(awk -F '=' '$1 == "CODEX_PATH" { sub(/^[^=]*=/, ""); print }' "$log_file" | tail -1)"
  codex_path_status="$(awk -F '=' '$1 == "CODEX_PATH_STATUS" { sub(/^[^=]*=/, ""); print }' "$log_file" | tail -1)"
  codex_version="$(awk -F '=' '$1 == "CODEX_VERSION" { sub(/^[^=]*=/, ""); print }' "$log_file" | tail -1)"

  say ""
  if [[ "$ssh_status" -eq 0 && "$install_status" == "ok" ]]; then
    status_item ok "自动安装" "Codex CLI 安装成功" "${codex_path:-codex}${codex_version:+ ($codex_version)}"
    if [[ "$codex_path_status" == "installed_not_in_path" ]]; then
      handle_codex_path_fix_prompt "$alias" "\$HOME/.local/bin"
    fi
    say ""
    say "接下来请在远程主机完成 Codex 登录："
    command_hint "ssh $alias"
    command_hint "codex"
    dim "登录完成后，再回到本菜单选择 7 检查状态。"
    return 0
  fi

  status_item bad "自动安装" "安装失败" "${install_reason:-远程安装命令退出失败，详情见上方日志。}"
  say ""
  info "失败后可手动安装"
  print_manual_codex_install_commands "$alias" "$kernel" "$os_id" "$os_like"
  return 1
}

add_host_flow() {
  ensure_files
  say ""
  info "添加新的 SSH 主机"

  local alias hostname user port default_identity identity
  while true; do
    prompt "Host 别名，例如 my-server"
    alias="$REPLY"
    validate_alias "$alias" || continue
    if host_exists_in_config "$alias" && ! is_managed_host "$alias"; then
      err "Host $alias 已存在于 $SSH_CONFIG，且不是本工具管理的配置。"
      warn "为了避免误改，请换一个别名，或先手动处理现有配置。"
      continue
    fi
    break
  done

  prompt "服务器 IP 或域名"
  hostname="$REPLY"
  if [[ -z "$hostname" ]]; then
    err "服务器 IP 或域名不能为空。"
    return 1
  fi
  prompt "SSH 用户名" "$USER"
  user="$REPLY"
  prompt "SSH 端口" "22"
  port="$REPLY"
  if [[ "$port" != <-> ]]; then
    err "端口必须是数字。"
    return 1
  fi

  default_identity="$SSH_DIR/id_ed25519_codex_$(safe_alias "$alias")"
  choose_identity_file "$alias" "$default_identity"
  identity="$CHOSEN_IDENTITY"

  say ""
  info "即将配置："
  say "  Host:         $alias"
  say "  HostName:     $hostname"
  say "  User:         $user"
  say "  Port:         $port"
  say "  IdentityFile: $identity"
  confirm "继续生成/复用密钥并配置这个 Host？" "y" || return 0

  ensure_key_pair "$alias" "$identity" || return 1

  if confirm "现在把公钥上传到服务器？" "y"; then
    upload_public_key_to_target "$identity" "$user" "$hostname" "$port" || {
      err "公钥上传失败。你可以稍后从菜单里选择“上传/修复公钥登录”。"
      return 1
    }
  else
    warn "已跳过公钥上传，稍后可能仍需密码登录。"
  fi

  write_managed_host "$alias" "$hostname" "$user" "$port" "$identity"
  test_ssh_alias "$alias" || true

  say ""
  ok "Host $alias 已添加。"
  dim "Codex App 中可前往 Settings → Connections → SSH host，启用 $alias 并选择远程项目目录。"
}

view_hosts_flow() {
  ensure_files
  say ""
  info "本工具管理的 Host"
  local managed
  managed="$(list_managed_hosts)"
  if [[ -z "$managed" ]]; then
    dim "暂无。"
  else
    printf "%-22s %-28s %-16s %-6s %-38s %-10s\n" "Alias" "HostName" "User" "Port" "IdentityFile" "Status"
    say "--------------------------------------------------------------------------------------------------------------"
    print -r -- "$managed" | while IFS=$'\t' read -r alias hostname user port identity host_status; do
      printf "%-22s %-28s %-16s %-6s %-38s %-10s\n" "$alias" "$hostname" "$user" "$port" "$identity" "$host_status"
    done
  fi

  say ""
  info "$SSH_CONFIG 中的具体 Host"
  local all_hosts
  all_hosts="$(list_config_hosts)"
  if [[ -z "$all_hosts" ]]; then
    dim "暂无。"
  else
    print -r -- "$all_hosts" | while IFS= read -r alias; do
      if is_managed_host "$alias"; then
        say "  ${C_GREEN}managed${C_RESET}   $alias"
      else
        say "  ${C_DIM}external${C_RESET}  $alias"
      fi
    done
  fi
}

test_host_flow() {
  ensure_files
  choose_host "no" || return 0
  test_ssh_alias "$CHOSEN_HOST" || true
}

repair_key_flow() {
  ensure_files
  say ""
  info "上传/修复公钥登录"
  choose_host "yes" || return 0
  local alias="$CHOSEN_HOST"
  local hostname user port identity
  hostname="$(extract_managed_field "$alias" hostname)"
  user="$(extract_managed_field "$alias" user)"
  port="$(extract_managed_field "$alias" port)"
  identity="$(extract_managed_field "$alias" identity)"

  ensure_key_pair "$alias" "$identity" || return 1
  upload_public_key_to_target "$identity" "$user" "$hostname" "$port" || return 1
  test_ssh_alias "$alias" || true
}

update_host_flow() {
  ensure_files
  say ""
  info "更新本工具管理的 Host 配置"
  choose_host "yes" || return 0
  local alias="$CHOSEN_HOST"
  local hostname user port identity
  hostname="$(extract_managed_field "$alias" hostname)"
  user="$(extract_managed_field "$alias" user)"
  port="$(extract_managed_field "$alias" port)"
  identity="$(extract_managed_field "$alias" identity)"

  prompt "服务器 IP 或域名" "$hostname"; hostname="$REPLY"
  prompt "SSH 用户名" "$user"; user="$REPLY"
  prompt "SSH 端口" "$port"; port="$REPLY"
  choose_identity_file "$alias" "$identity"; identity="$CHOSEN_IDENTITY"
  if [[ "$port" != <-> ]]; then
    err "端口必须是数字。"
    return 1
  fi
  ensure_key_pair "$alias" "$identity" || return 1
  write_managed_host "$alias" "$hostname" "$user" "$port" "$identity"
  test_ssh_alias "$alias" || true
}

disable_or_delete_flow() {
  ensure_files
  say ""
  info "禁用或删除 Host"
  choose_host "yes" || return 0
  local alias="$CHOSEN_HOST"
  say ""
  say "1. 从 ~/.ssh/config 移除本工具配置块，并在记录中标记 disabled"
  say "2. 仅标记 disabled，不修改 ~/.ssh/config"
  say "3. 返回"
  prompt "请选择" "1"
  case "$REPLY" in
    1)
      backup_config
      remove_managed_block "$alias"
      mark_registry_status "$alias" "disabled"
      ok "已从 $SSH_CONFIG 移除 Host $alias 的本工具配置块。"
      ;;
    2)
      mark_registry_status "$alias" "disabled"
      ok "已标记为 disabled。"
      ;;
    *)
      return 0
      ;;
  esac
  warn "密钥文件和服务器 authorized_keys 未删除。"
}

codex_check_flow() {
  ensure_files
  say ""
  info "检查 Codex App 远程连接准备情况"
  choose_host "no" || return 0
  local alias="$CHOSEN_HOST"

  say ""
  info "步骤 1/2：检查 SSH"
  if ! test_ssh_alias "$alias"; then
    say ""
    status_item bad "整体状态" "暂不可用于 Codex App" "SSH 尚未连通，后续远程 Codex 检查已跳过。"
    return 0
  fi

  say ""
  info "步骤 2/2：检查远程运行环境"
  local remote_info
  if ! remote_info="$(ssh -F "$SSH_CONFIG" "$alias" '
    if [ -r /etc/os-release ]; then
      . /etc/os-release
    fi
    kernel="$(uname -s 2>/dev/null || true)"
    codex_path="$(command -v codex 2>/dev/null || true)"
    local_codex="$HOME/.local/bin/codex"
    standalone_codex="$HOME/.codex/packages/standalone/current/codex"
    codex_status="missing"
    codex_runnable=""
    if [ -n "$codex_path" ]; then
      codex_status="path"
      codex_runnable="$codex_path"
    elif [ -x "$local_codex" ]; then
      codex_status="installed_not_in_path"
      codex_runnable="$local_codex"
    elif [ -x "$standalone_codex" ]; then
      codex_status="installed_not_in_path"
      codex_runnable="$standalone_codex"
    fi
    node_path="$(command -v node 2>/dev/null || true)"
    npm_path="$(command -v npm 2>/dev/null || true)"
    printf "kernel=%s\n" "$kernel"
    printf "os=%s\n" "${PRETTY_NAME:-unknown}"
    printf "os_id=%s\n" "${ID:-unknown}"
    printf "os_like=%s\n" "${ID_LIKE:-}"
    printf "shell=%s\n" "$SHELL"
    printf "codex_path=%s\n" "$codex_path"
    printf "codex_status=%s\n" "$codex_status"
    printf "codex_runnable=%s\n" "$codex_runnable"
    printf "local_bin=%s\n" "$HOME/.local/bin"
    if [ -n "$codex_runnable" ]; then
      printf "codex_version=%s\n" "$("$codex_runnable" --version 2>/dev/null || true)"
    else
      printf "codex_version=\n"
    fi
    printf "node_path=%s\n" "$node_path"
    if [ -n "$node_path" ]; then
      printf "node_version=%s\n" "$(node --version 2>/dev/null || true)"
    else
      printf "node_version=\n"
    fi
    printf "npm_path=%s\n" "$npm_path"
    if [ -n "$npm_path" ]; then
      printf "npm_version=%s\n" "$(npm --version 2>/dev/null || true)"
    else
      printf "npm_version=\n"
    fi
  ')"; then
    status_item bad "远程检查" "无法读取远程环境" "SSH 已连通，但远程命令执行失败。可使用菜单 8 查看详细 SSH 日志。"
    return 0
  fi

  local kernel os os_id os_like shell_name codex_path codex_status codex_runnable local_bin codex_version node_path node_version npm_path npm_version
  kernel="$(kv_get "$remote_info" kernel)"
  os="$(kv_get "$remote_info" os)"
  os_id="$(kv_get "$remote_info" os_id)"
  os_like="$(kv_get "$remote_info" os_like)"
  shell_name="$(kv_get "$remote_info" shell)"
  codex_path="$(kv_get "$remote_info" codex_path)"
  codex_status="$(kv_get "$remote_info" codex_status)"
  codex_runnable="$(kv_get "$remote_info" codex_runnable)"
  local_bin="$(kv_get "$remote_info" local_bin)"
  codex_version="$(kv_get "$remote_info" codex_version)"
  node_path="$(kv_get "$remote_info" node_path)"
  node_version="$(kv_get "$remote_info" node_version)"
  npm_path="$(kv_get "$remote_info" npm_path)"
  npm_version="$(kv_get "$remote_info" npm_version)"

  say ""
  info "状态摘要"
  status_item ok "SSH" "$alias 可连接" "本机到远程主机的免密 SSH 已满足 Codex App 前置条件。"
  status_item info "远程系统" "${os:-unknown}" "kernel=${kernel:-unknown}；shell=${shell_name:-unknown}"

  if [[ -n "$node_path" ]]; then
    status_item ok "Node.js" "$node_path ${node_version:+($node_version)}"
  else
    status_item warn "Node.js" "未找到 node" "安装 Codex CLI 前通常需要先安装 Node.js。"
  fi

  if [[ -n "$npm_path" ]]; then
    status_item ok "npm" "$npm_path ${npm_version:+($npm_version)}"
  else
    status_item warn "npm" "未找到 npm" "无法通过 npm 安装 @openai/codex。"
  fi

  if [[ "$codex_status" == "path" ]]; then
    status_item ok "Codex CLI" "$codex_path ${codex_version:+($codex_version)}" "远程登录 shell 的 PATH 已经能找到 codex。"
  elif [[ "$codex_status" == "installed_not_in_path" ]]; then
    status_item warn "Codex CLI" "$codex_runnable ${codex_version:+($codex_version)}" "Codex 已安装，但远程 PATH 缺少 ${local_bin:-~/.local/bin}，直接输入 codex 会失败。"
  else
    status_item warn "Codex CLI" "未安装" "未在 PATH 或 standalone 默认位置找到 codex。"
  fi

  say ""
  if [[ "$codex_status" == "path" ]]; then
    status_item ok "整体状态" "基本就绪" "接下来去 Codex App 的 Settings → Connections 中添加或启用 $alias。"
  elif [[ "$codex_status" == "installed_not_in_path" ]]; then
    status_item warn "整体状态" "需要修复 PATH" "Codex 已安装，但交互式 shell 不能直接运行 codex。"
  else
    status_item warn "整体状态" "还差 Codex CLI" "SSH 已通，但远程缺少 codex 命令。"
  fi

  if [[ "$codex_status" == "installed_not_in_path" ]]; then
    handle_codex_path_fix_prompt "$alias" "${local_bin:-$HOME/.local/bin}"
  elif [[ "$codex_status" == "missing" || -z "$codex_status" ]]; then
    say ""
    info "建议下一步"
    print_manual_codex_install_commands "$alias" "$kernel" "$os_id" "$os_like"
    say ""
    if confirm "是否现在尝试自动安装 Codex CLI？" "n"; then
      remote_install_codex "$alias" "$kernel" "$os_id" "$os_like" || true
    else
      warn "已跳过自动安装。你可以按上面的命令手动安装。"
    fi
  fi
  say ""
  dim "Codex App 要求：本机 ssh $alias 成功，并且远程登录 shell 的 PATH 中能找到 codex。"
}

remote_codex_browser_login_flow() {
  ensure_files
  say ""
  info "远程 Codex 浏览器登录"
  choose_host "no" || return 0
  local alias="$CHOSEN_HOST"
  local port="${CODEX_LOGIN_PORT:-1455}"
  local tunnel_pid="" login_status=0 opened_url_file log_file

  opened_url_file="$(mktemp)"
  log_file="$(mktemp)"

  say ""
  info "步骤 1/4：检查 SSH"
  if ! test_ssh_alias "$alias"; then
    status_item bad "整体状态" "无法登录" "SSH 不通，无法启动远程 codex login。"
    return 0
  fi

  say ""
  info "步骤 2/4：检查远程 Codex CLI"
  local probe codex_status codex_runnable local_bin
  if ! probe="$(remote_codex_probe "$alias" 2>/dev/null)"; then
    status_item bad "Codex CLI" "无法检查远程 codex" "请先通过菜单 7 查看远程环境。"
    return 0
  fi
  codex_status="$(kv_get "$probe" codex_status)"
  codex_runnable="$(kv_get "$probe" codex_runnable)"
  local_bin="$(kv_get "$probe" local_bin)"
  if [[ "$codex_status" == "missing" || -z "$codex_runnable" ]]; then
    status_item bad "Codex CLI" "远程未找到 codex" "请先通过菜单 7 检查并安装 Codex CLI。"
    return 0
  fi
  if [[ "$codex_status" == "installed_not_in_path" ]]; then
    status_item warn "Codex CLI" "$codex_runnable" "已安装但 PATH 缺少 $local_bin；本次会用完整路径启动。"
    handle_codex_path_fix_prompt "$alias" "$local_bin"
  else
    status_item ok "Codex CLI" "$codex_runnable" "即将启动 codex login。"
  fi

  say ""
  info "步骤 3/4：建立 localhost:$port 端口转发"
  if ! local_port_is_free "$port"; then
    status_item bad "本机端口" "localhost:$port 已被占用" "Codex 登录回调固定使用 localhost:$port；请关闭占用该端口的程序后重试。"
    if command -v lsof >/dev/null 2>&1; then
      say ""
      info "占用端口的进程"
      lsof -nP -iTCP:"$port" -sTCP:LISTEN || true
    fi
    return 0
  fi

  ssh -F "$SSH_CONFIG" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=2 \
    -N -L "${port}:127.0.0.1:${port}" "$alias" &
  tunnel_pid=$!
  sleep 1

  if ! kill -0 "$tunnel_pid" >/dev/null 2>&1; then
    status_item bad "端口转发" "启动失败" "命令：ssh -N -L ${port}:127.0.0.1:${port} $alias"
    return 0
  fi
  status_item ok "端口转发" "localhost:$port -> $alias:127.0.0.1:$port" "浏览器回调会从你的 Mac 转发到远程 codex login。"

  say ""
  info "步骤 4/4：启动远程 codex login"
  dim "看到 auth.openai.com URL 后，脚本只会显示链接，不会自动打开浏览器。"
  dim "请复制链接到你自己选择的浏览器中完成登录。"
  warn "登录完成前请不要关闭本窗口；完成或中断后脚本会关闭端口转发。"
  say ""

  {
    {
      ssh -tt -F "$SSH_CONFIG" "$alias" "'$codex_runnable' login" 2>&1
    } | while IFS= read -r line; do
      print -r -- "$line" | tee -a "$log_file"
      if [[ ! -s "$opened_url_file" && "$line" == https://auth.openai.com/* ]]; then
        print -r -- "$line" > "$opened_url_file"
        say ""
        status_item ok "登录 URL" "已捕获，请手动复制到浏览器打开"
        url_hint "$line"
        say ""
      fi
    done
    login_status=${pipestatus[1]}
  } always {
    say ""
    if [[ -n "$tunnel_pid" ]] && kill -0 "$tunnel_pid" >/dev/null 2>&1; then
      kill "$tunnel_pid" >/dev/null 2>&1 || true
      wait "$tunnel_pid" 2>/dev/null || true
      status_item ok "端口转发" "已关闭" "localhost:$port 转发进程已清理。"
    fi
  }

  if [[ "$login_status" -eq 0 ]]; then
    status_item ok "登录流程" "远程 codex login 已结束" "如浏览器显示授权完成，远程 Codex CLI 应已登录。"
  else
    status_item warn "登录流程" "codex login 未正常结束" "如果你按了 Ctrl-C 或浏览器未完成回调，可以重新运行本功能。日志：$log_file"
    if grep -qi "Country, region, or territory not supported" "$log_file"; then
      status_item bad "失败原因" "远端出口地区不受支持" "OpenAI token exchange 返回 403；请检查远端服务器出口网络或改用受支持地区的远端环境。"
    elif grep -qi "Token exchange.*403\\|403 Forbidden" "$log_file"; then
      status_item bad "失败原因" "Token exchange 被拒绝" "日志中出现 403，通常与远端出口地区、网络策略或账号访问环境有关。"
    fi
  fi

  say ""
  dim "也可以使用无需端口转发的方式：codex login --device-auth。"
}

remote_codex_device_login_flow() {
  ensure_files
  say ""
  info "远程 Codex Device Auth 登录"
  choose_host "no" || return 0
  local alias="$CHOSEN_HOST"

  if ! test_ssh_alias "$alias"; then
    status_item bad "整体状态" "无法登录" "SSH 不通，无法启动远程 codex login --device-auth。"
    return 0
  fi
  local probe codex_status codex_runnable local_bin
  if ! probe="$(remote_codex_probe "$alias" 2>/dev/null)"; then
    status_item bad "Codex CLI" "无法检查远程 codex" "请先通过菜单 7 查看远程环境。"
    return 0
  fi
  codex_status="$(kv_get "$probe" codex_status)"
  codex_runnable="$(kv_get "$probe" codex_runnable)"
  local_bin="$(kv_get "$probe" local_bin)"
  if [[ "$codex_status" == "missing" || -z "$codex_runnable" ]]; then
    status_item bad "Codex CLI" "远程未找到 codex" "请先通过菜单 7 检查并安装 Codex CLI。"
    return 0
  fi
  if [[ "$codex_status" == "installed_not_in_path" ]]; then
    status_item warn "Codex CLI" "$codex_runnable" "已安装但 PATH 缺少 $local_bin；本次会用完整路径启动。"
    handle_codex_path_fix_prompt "$alias" "$local_bin"
  fi

  say ""
  status_item info "Device Auth" "无需 localhost 端口转发" "按远程输出的设备码和 URL 完成登录。"
  ssh -tt -F "$SSH_CONFIG" "$alias" "'$codex_runnable' login --device-auth"
}

remote_codex_login_flow() {
  ensure_files
  say ""
  info "登录远程 Codex CLI"
  say "1. 浏览器登录，自动转发 localhost:1455"
  say "2. Device Auth 登录，不需要端口转发"
  say "3. 返回"
  prompt "请选择" "1"
  case "$REPLY" in
    1) remote_codex_browser_login_flow ;;
    2) remote_codex_device_login_flow ;;
    *) return 0 ;;
  esac
}

diagnose_flow() {
  ensure_files
  say ""
  info "诊断连接问题"
  choose_host "no" || return 0
  local alias="$CHOSEN_HOST"
  say ""
  warn "下面会运行 ssh -v 的前 120 行输出，里面可能包含本机路径和主机信息。"
  confirm "继续诊断？" "y" || return 0
  ssh -F "$SSH_CONFIG" -v -o ConnectTimeout=8 "$alias" true 2>&1 | sed -n '1,120p'
}

print_header() {
  clear 2>/dev/null || true
  say "${C_BOLD}${TOOL_NAME}${C_RESET}"
  dim "配置文件：$SSH_CONFIG"
  dim "管理记录：$REGISTRY_FILE"
  say ""
  print_key_dashboard
}

main_menu() {
  ensure_files
  while true; do
    print_header
    say "1. 添加 SSH 主机"
    say "2. 查看 SSH 主机"
    say "3. 测试 SSH 连接"
    say "4. 上传/修复公钥登录"
    say "5. 更新 SSH Host 配置"
    say "6. 禁用或删除 Host"
    say "7. 检查 Codex App 远程连接准备情况"
    say "8. 登录远程 Codex CLI"
    say "9. 诊断连接问题"
    say "10. 退出"
    say ""
    prompt "请选择" "1"
    case "$REPLY" in
      1) add_host_flow; pause ;;
      2) view_hosts_flow; pause ;;
      3) test_host_flow; pause ;;
      4) repair_key_flow; pause ;;
      5) update_host_flow; pause ;;
      6) disable_or_delete_flow; pause ;;
      7) codex_check_flow; pause ;;
      8) remote_codex_login_flow; pause ;;
      9) diagnose_flow; pause ;;
      10|q|quit|exit) say "再见。"; return 0 ;;
      *) warn "请输入 1-10。"; sleep 1 ;;
    esac
  done
}

usage() {
  say "$TOOL_NAME"
  say ""
  say "用法："
  say "  $SCRIPT_PATH                 打开交互式菜单"
  say "  $SCRIPT_PATH list            查看 Host"
  say "  $SCRIPT_PATH test <host>     测试 SSH 连接"
  say "  $SCRIPT_PATH codex <host>    检查远程 Codex 准备情况"
  say ""
  say "测试用环境变量："
  say "  CODEX_SSH_CONFIG=/tmp/config CODEX_SSH_HOME=/tmp/state $SCRIPT_PATH"
}

case "${1:-menu}" in
  menu) main_menu ;;
  list) ensure_files; view_hosts_flow ;;
  test)
    ensure_files
    if [[ -z "${2:-}" ]]; then err "缺少 host。"; exit 2; fi
    test_ssh_alias "$2"
    ;;
  codex)
    ensure_files
    if [[ -z "${2:-}" ]]; then err "缺少 host。"; exit 2; fi
    CHOSEN_HOST="$2"
    if test_ssh_alias "$CHOSEN_HOST"; then
      ssh -F "$SSH_CONFIG" "$CHOSEN_HOST" 'command -v codex && codex --version'
    fi
    ;;
  -h|--help|help) usage ;;
  *) err "未知命令：$1"; usage; exit 2 ;;
esac
