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
  info "测试免交互 SSH：ssh -F $SSH_CONFIG -o BatchMode=yes $alias true"
  if ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=8 "$alias" true; then
    ok "SSH 连接成功：$alias"
    return 0
  fi
  err "SSH 免交互连接失败：$alias"
  warn "如果这是首次上传公钥前的主机，失败是正常的。诊断可运行：ssh -F $SSH_CONFIG -v $alias"
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

  if ! test_ssh_alias "$alias"; then
    warn "SSH 不通时，Codex App 也无法使用这个 Host。请先修复 SSH。"
    return 0
  fi

  say ""
  info "检查远程系统和 codex 命令"
  ssh -F "$SSH_CONFIG" "$alias" 'printf "kernel=%s\n" "$(uname -s 2>/dev/null || true)"; if [ -r /etc/os-release ]; then . /etc/os-release; printf "os=%s\n" "${PRETTY_NAME:-unknown}"; fi; printf "shell=%s\n" "$SHELL"; printf "codex=%s\n" "$(command -v codex 2>/dev/null || true)"; if command -v codex >/dev/null 2>&1; then codex --version 2>/dev/null || true; fi; printf "node=%s\n" "$(command -v node 2>/dev/null || true)"; printf "npm=%s\n" "$(command -v npm 2>/dev/null || true)"'

  say ""
  info "下一步判断"
  dim "Codex App 要求：本机 ssh $alias 能成功；远程登录 shell 的 PATH 里能找到 codex。"
  say "如果远程没有 codex，可根据系统选择安装方式："
  say "  Debian/Ubuntu: sudo apt update && sudo apt install -y nodejs npm && sudo npm i -g @openai/codex"
  say "  Fedora/RHEL:   sudo dnf install -y nodejs npm && sudo npm i -g @openai/codex"
  say "  Arch:          sudo pacman -S nodejs npm && sudo npm i -g @openai/codex"
  say "  macOS:         brew install node && npm i -g @openai/codex"
  say ""
  dim "安装后在远程运行 codex 完成登录，再回到 Codex App → Settings → Connections 添加/启用 $alias。"
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
    say "8. 诊断连接问题"
    say "9. 退出"
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
      8) diagnose_flow; pause ;;
      9|q|quit|exit) say "再见。"; return 0 ;;
      *) warn "请输入 1-9。"; sleep 1 ;;
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
