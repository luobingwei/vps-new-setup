#!/usr/bin/env bash
# ============================================================
#  vps-setup — 新 VPS 常用工具环境一键安装脚本
#
#  复刻通用 VPS 部署流程（核心 5 步）:
#    1. swap        —— 自动创建交换分区（也可用 zhucaidan/swap.sh）
#    2. bbr         —— BBR3 内核/网络优化（byJoey Actions-bbr-v3，交互式）
#    3. reboot      —— 每天凌晨 4 点自动重启（crontab）
#    4. ssh         —— 从 GitHub 拉公钥 + 改端口 2222 + 仅密钥登录
#    5. zsh         —— Zsh + Oh My Zsh + powerlevel10k，应用配置、跳过向导
#
#  用法:
#    bash setup.sh                 # 默认：环境预检 + 终端交互式勾选菜单（推荐）
#    bash setup.sh --auto          # 全自动，跳过菜单与交互（用配置文件里的值）
#    bash setup.sh -m swap,ssh     # 只装指定模块（逗号分隔）
#    bash setup.sh --dry-run       # 只预览将要执行的操作，不真正安装
#
#  要求: 以 root 或 sudo 运行；支持 Debian/Ubuntu、CentOS/Rocky/Alma/Fedora
#  运行前会自动预检环境（必需工具/磁盘空间），不满足会提示并停止。
# ============================================================
set -euo pipefail

# 兼容管道运行（curl ... | bash -s）：此时 BASH_SOURCE[0] 为空，退回当前目录。
# 管道方式下没有 conf/ 目录，配置一律用默认值；p10k 用内置默认配置。
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR="$(pwd)"
fi
CONF_FILE="${SCRIPT_DIR}/conf/setup.conf"
LOG_FILE="/var/log/vps-setup.log"

# 兜底终端类型：避免 whiptail 在部分终端(如网页/VNC 控制台、TERM 为空或 dumb)渲染异常
if [[ -z "$TERM" || "$TERM" == "dumb" ]]; then
  export TERM="${TERM:-xterm}"
fi

# ---------------- 配置加载 ----------------
load_config() {
  if [[ ! -f "$CONF_FILE" ]]; then
    echo "⚠️  未找到配置文件 ${CONF_FILE}，将使用默认值。"
    return
  fi
  # shellcheck disable=SC1090
  source "$CONF_FILE"
}
load_config

# 默认值（配置缺失时生效）
SETUP_SWAP="${SETUP_SWAP:-true}"
SWAP_METHOD="${SWAP_METHOD:-native}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SETUP_BBR="${SETUP_BBR:-true}"
BBR_METHOD="${BBR_METHOD:-native}"
BBR_SCRIPT_URL="${BBR_SCRIPT_URL:-https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh}"
SETUP_DAILY_REBOOT="${SETUP_DAILY_REBOOT:-true}"
REBOOT_CRON="${REBOOT_CRON:-0 4 * * *}"
SETUP_SSH="${SETUP_SSH:-true}"
SSH_GITHUB_USER="${SSH_GITHUB_USER:-}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_OVERWRITE_KEYS="${SSH_OVERWRITE_KEYS:-true}"
SSH_DISABLE_PASSWORD="${SSH_DISABLE_PASSWORD:-true}"
INSTALL_ZSH="${INSTALL_ZSH:-true}"
# 要启用的 zsh 插件（空格分隔）。前 6 个为 oh-my-zsh 内置；zsh-* 开头的会自动额外安装
ZSH_PLUGINS="${ZSH_PLUGINS:-git zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search}"
P10K_CONFIG_URL="${P10K_CONFIG_URL:-}"

# ---------------- 全局变量 ----------------
AUTO_YES=false
DRY_RUN=false
INTERACTIVE_MENU=false
declare -a ONLY_MODULES=()
FULL_MODULES=("swap" "bbr" "reboot" "ssh" "zsh")

# ---------------- 基础函数 ----------------
log()  { printf '\033[1;32m[ ✔ ]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
info() { printf '\033[1;34m[ .. ]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
warn() { printf '\033[1;33m[ !! ]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
err()  { printf '\033[1;31m[ ✗ ]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      info "当前非 root，将使用 sudo 执行。"
      exec sudo bash "$0" "$@"
    else
      err "需要 root 权限，请以 root 用户运行（或使用 sudo）。"
      exit 1
    fi
  fi
}

confirm() {
  [[ "$AUTO_YES" == true ]] && return 0
  local prompt="$1"
  read -r -p "$prompt [y/N] " ans </dev/tty || ans=""
  [[ "$ans" =~ ^[Yy]$ ]]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ---------------- OS 检测 ----------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="$ID"
    OS_NAME="$NAME"
  else
    OS_ID="unknown"; OS_NAME="unknown"
  fi

  case "$OS_ID" in
    ubuntu|debian)
      PKG_MANAGER="apt"
      PKG_UPDATE="apt-get update -y"
      PKG_INSTALL="apt-get install -y"
      ;;
    centos|rhel|rocky|alma|fedora|amzn)
      PKG_MANAGER="dnf"
      PKG_UPDATE="dnf makecache -y"
      PKG_INSTALL="dnf install -y"
      if [[ "$OS_ID" == "centos" && "${VERSION_ID%%.*}" -lt 8 ]]; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum makecache -y"
        PKG_INSTALL="yum install -y"
      fi
      ;;
    *)
      err "暂不支持的操作系统: $OS_NAME ($OS_ID)。当前支持 Debian/Ubuntu 与 CentOS/Rocky/Alma/Fedora。"
      exit 1
      ;;
  esac
  info "检测到操作系统: $OS_NAME ($OS_ID)，包管理器: $PKG_MANAGER"
}

# ---------------- 运行环境预检 ----------------
# 二进制名 → 各包管理器下的安装包名（仅用于自动补装）
tool_pkg() {
  case "$PKG_MANAGER" in
    apt)
      case "$1" in
        crontab) echo cron ;;
        sysctl) echo procps ;;
        mkswap|fallocate) echo util-linux ;;
        *) echo "$1" ;;
      esac ;;
    dnf|yum)
      case "$1" in
        crontab) echo cronie ;;
        sysctl) echo procps-ng ;;
        mkswap|fallocate) echo util-linux ;;
        *) echo "$1" ;;
      esac ;;
  esac
}

# 检查新 VPS 运行条件；缺失的必需工具会自动安装，装不上才停止。
check_environment() {
  info "环境预检..."
  # awk/sed/grep/tar 为系统基础，正常都在；以下常在新机器上缺失：
  local required=(curl wget git crontab sysctl mkswap awk sed grep tar)
  local -a to_install=() missing=()
  local c
  for c in "${required[@]}"; do
    if ! command_exists "$c"; then
      to_install+=("$(tool_pkg "$c")")
      missing+=("$c")
    fi
  done

  if [[ "${#to_install[@]}" -gt 0 ]]; then
    info "检测到缺少工具: ${missing[*]}，正在自动安装（${PKG_INSTALL} ${to_install[*]}）..."
    if $DRY_RUN; then
      echo "  (dry) 将安装: ${to_install[*]}"
    else
      $PKG_UPDATE
      $PKG_INSTALL "${to_install[@]}" || {
        err "自动安装失败，请手动执行后重试: ${PKG_INSTALL} ${to_install[*]}"
        exit 1
      }
    fi
    # 复查（dry-run 未真正安装，跳过失败判定，只提示将安装哪些）
    if ! $DRY_RUN; then
      local -a still=()
      for c in "${missing[@]}"; do command_exists "$c" || still+=("$c"); done
      if [[ "${#still[@]}" -gt 0 ]]; then
        err "仍有工具缺失: ${still[*]}，无法继续。"
        exit 1
      fi
    fi
  fi

  # 可选工具（缺失不阻断，仅提示）
  local optional=(whiptail jq fallocate)
  local missopt=()
  for c in "${optional[@]}"; do
    command_exists "$c" || missopt+=("$c")
  done
  [[ "${#missopt[@]}" -gt 0 ]] && warn "可选工具缺失（不影响核心功能）: ${missopt[*]}"

  # 磁盘空间检查（swap 需要）
  if [[ "$SETUP_SWAP" == "true" ]]; then
    local swap_mb free_mb
    swap_mb=$([[ "$SWAP_SIZE" =~ ^([0-9]+)G$ ]] && echo "$((BASH_REMATCH[1] * 1024))" || echo "2048")
    free_mb=$(df -m / | awk 'NR==2 {print $4}')
    if (( free_mb < swap_mb )); then
      warn "磁盘空间仅剩 ${free_mb}MB，可能不足以创建 ${SWAP_SIZE} 的 swap（约需 ${swap_mb}MB）。"
    else
      info "磁盘空间充足（剩余 ${free_mb}MB，swap 需约 ${swap_mb}MB）。"
    fi
  fi
  log "运行环境预检通过"
}

# ---------------- 参数解析 ----------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto|-y)         AUTO_YES=true ;;
      --menu)            INTERACTIVE_MENU=true ;;
      --dry-run)         DRY_RUN=true ;;
      -m|--modules)      shift; IFS=',' read -r -a ONLY_MODULES <<< "$1" ;;
      -h|--help)
        sed -n '2,14p' "$0"
        exit 0
        ;;
      *) warn "忽略未知参数: $1" ;;
    esac
    shift
  done
  if [[ "${#ONLY_MODULES[@]}" -gt 0 ]]; then
    info "本次仅执行模块: ${ONLY_MODULES[*]}"
  fi
  return 0
}

module_enabled() {
  if [[ "${#ONLY_MODULES[@]}" -gt 0 ]]; then
    for m in "${ONLY_MODULES[@]}"; do [[ "$m" == "$1" ]] && return 0; done
    return 1
  fi
  return 0
}

# ---------------- 交互式模块选择菜单 ----------------
# 模块名 → 中文说明
module_label() {
  case "$1" in
    swap) echo "swap 交换分区" ;;
    bbr)  echo "BBR 网络优化" ;;
    reboot) echo "每日4点自动重启" ;;
    ssh)  echo "SSH 密钥+改端口2222" ;;
    zsh)  echo "Zsh + OhMyZsh + p10k" ;;
    *) echo "$1" ;;
  esac
}

# 模块 → 默认是否勾选（读配置开关）
module_default_on() {
  local v
  case "$1" in
    swap) v="$SETUP_SWAP" ;;
    bbr)  v="$SETUP_BBR" ;;
    reboot) v="$SETUP_DAILY_REBOOT" ;;
    ssh)  v="$SETUP_SSH" ;;
    zsh)  v="$INSTALL_ZSH" ;;
    *) v="false" ;;
  esac
  [[ "$v" == "true" ]] && echo "true" || echo "false"
}

# 纯 bash 降级菜单（无 whiptail 时使用）
pure_bash_menu() {
  local -a names=("$@")
  local -a toggled=()
  local n i t ch mark found
  for n in "${names[@]}"; do
    [[ "$(module_default_on "$n")" == "true" ]] && toggled+=("$n")
  done
  while true; do
    echo
    echo "  vps-setup 模块选择："
    for i in "${!names[@]}"; do
      mark=" "
      for t in "${toggled[@]}"; do [[ "$t" == "${names[$i]}" ]] && mark="x"; done
      printf "    %2d) [%s] %-11s %s\n" $((i + 1)) "$mark" "${names[$i]}" "$(module_label "${names[$i]}")"
    done
    echo
    printf "  Choice: 1-${#names[@]} 切换勾选 / a 全选 / n 全不选 / q 确认并开始: "
    if ! read -r ch </dev/tty; then
      warn "无法进行交互选择，按当前勾选模块继续。"
      break
    fi
    ch="${ch:-}"
    [[ "$ch" == "q" ]] && break
    [[ "$ch" == "a" ]] && { toggled=("${names[@]}"); continue; }
    [[ "$ch" == "n" ]] && { toggled=(); continue; }
    if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#names[@]} )); then
      local idx=$((ch - 1))
      found=0
      local -a nt=()
      for t in "${toggled[@]}"; do
        if [[ "$t" == "${names[$idx]}" ]]; then found=1; else nt+=("$t"); fi
      done
      [[ "$found" -eq 0 ]] && nt+=("${names[$idx]}")
      toggled=("${nt[@]}")
    else
      echo "  无效输入，请输数字(1-${#names[@]})或 a/n/q"
    fi
  done
  ONLY_MODULES=("${toggled[@]}")
}

# 主菜单：优先 whiptail 勾选界面，否则纯 bash 降级
show_module_menu() {
  local -a names=(swap bbr reboot ssh zsh)
  # 环境变量 VPS_SETUP_MENU=plain 可强制走纯文本菜单（兼容 whiptail 渲染异常的终端）
  if [[ "${VPS_SETUP_MENU:-whiptail}" != "plain" ]] && command -v whiptail >/dev/null 2>&1; then
    local -a items=()
    local n st
    for n in "${names[@]}"; do
      st=$(module_default_on "$n")
      items+=("$n" "$(module_label "$n")" "$([[ "$st" == "true" ]] && echo ON || echo OFF)")
    done
    local out
    if out=$(whiptail --title "vps-setup 模块选择" \
        --checklist "空格 勾选/取消，Tab 切换，回车 确认" \
        22 62 "${#names[@]}" "${items[@]}" 3>&1 1>&2 2>&3); then
      read -r -a ONLY_MODULES <<< "$out"
      # whiptail 输出带引号（"swap" "ssh"），去掉引号以便匹配模块名
      local i
      for i in "${!ONLY_MODULES[@]}"; do
        ONLY_MODULES[$i]=$(echo "${ONLY_MODULES[$i]}" | tr -d '"')
      done
    else
      err "已取消选择，退出。"
      exit 1
    fi
  else
    pure_bash_menu "${names[@]}"
  fi
  info "本次将安装模块: ${ONLY_MODULES[*]:-（无）}"
  if [[ "${#ONLY_MODULES[@]}" -eq 0 ]]; then
    warn "未选择任何模块，退出。"
    exit 0
  fi
}

# ============================================================
#  ★ 核心模块 ★
# ============================================================

# ---------- 1. swap ----------
setup_swap() {
  module_enabled swap || return 0
  [[ "$SETUP_SWAP" != "true" ]] && return 0

  if swapon --show 2>/dev/null | grep -q .; then
    info "已存在 swap，跳过。"
    return 0
  fi

  if [[ "$SWAP_METHOD" == "script" ]]; then
    info "调用 zhucaidan/swap.sh 交互脚本..."
    if $DRY_RUN; then echo "  (dry) wget swap.sh && bash swap.sh"; return 0; fi
    cd /tmp
    wget -q https://raw.githubusercontent.com/zhucaidan/swap.sh/main/swap.sh -O swap.sh
    bash swap.sh
    return 0
  fi

  info "自动创建 ${SWAP_SIZE} swap 交换分区..."
  if $DRY_RUN; then echo "  (dry) fallocate 创建 ${SWAP_SIZE} swapfile 并写入 fstab"; return 0; fi

  fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE%G}000" status=progress
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log "swap 配置完成（${SWAP_SIZE}）"
}

# ---------- 2. BBR / BBRv3 ----------
setup_bbr() {
  module_enabled bbr || return 0
  [[ "$SETUP_BBR" != "true" ]] && return 0

  # 第三方脚本方式（需在配置里手动开启；会下载并安装未审计的自定义内核）
  if [[ "$BBR_METHOD" == "script" ]]; then
    info "执行第三方 BBR3 脚本（byJoey Actions-bbr-v3）..."
    if $DRY_RUN; then echo "  (dry) bash <(curl -fsSL $BBR_SCRIPT_URL)"; return 0; fi
    warn "⚠️ 该方式会从 byJoey 下载并安装自定义内核 .deb（未审计的编译产物），存在供应链风险，默认不推荐。"
    bash <(curl -fsSL "$BBR_SCRIPT_URL")
    return 0
  fi

  # 原生方式：仅用 sysctl 启用 BBR + FQ，不安装任何第三方内核。
  # 内核 ≥6.8（Ubuntu 24.04 / Debian 12）系统自带的 bbr 即 BBRv3；更旧内核为 BBRv1。
  info "原生启用 BBR + FQ（不安装第三方内核）..."
  if $DRY_RUN; then echo "  (dry) 设置 default_qdisc=fq, tcp_congestion_control=bbr"; return 0; fi

  # 检测内核是否支持 bbr（不支持则加载模块再试）
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      warn "当前内核不支持 BBR，跳过。内核版本: $(uname -r)"
      return 0
    fi
  fi

  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

  # 持久化（重启后仍生效）
  local bconf="/etc/sysctl.d/99-vps-setup-bbr.conf"
  cat > "$bconf" <<'BBR_EOF'
# vps-setup: 原生启用 BBR（内核≥6.8 即 BBRv3）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBR_EOF
  sysctl --system >/dev/null 2>&1 || true

  log "BBR 已启用（算法=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)，队列=$(sysctl -n net.core.default_qdisc 2>/dev/null)）"
}

# ---------- 3. 每天凌晨 4 点自动重启 ----------
setup_daily_reboot() {
  module_enabled reboot || return 0
  [[ "$SETUP_DAILY_REBOOT" != "true" ]] && return 0
  info "添加每日定时重启: $REBOOT_CRON"
  if $DRY_RUN; then echo "  (dry) crontab 写入: $REBOOT_CRON /sbin/shutdown -r now"; return 0; fi

  # 幂等：已存在则不重复添加
  if crontab -l 2>/dev/null | grep -qF "/sbin/shutdown -r now"; then
    info "定时重启已存在，跳过。"
    return 0
  fi
  (crontab -l 2>/dev/null; echo "$REBOOT_CRON /sbin/shutdown -r now") | crontab -
  log "已添加每日自动重启（$REBOOT_CRON）"
}

# ---------- 4. SSH：GitHub 公钥 + 改端口 + 仅密钥 ----------
setup_ssh() {
  module_enabled ssh || return 0
  [[ "$SETUP_SSH" != "true" ]] && return 0

  # 获取 GitHub 用户名（每个人都有自己对应的公钥，默认不带任何用户名）：
  # 配置为空 → 交互时提示输入；输入为空/拉不到公钥 → 跳过 SSH 模块，不阻塞后续安装
  if [[ -z "$SSH_GITHUB_USER" ]]; then
    if [[ "$AUTO_YES" != true ]]; then
      read -r -p "请输入 GitHub 用户名（用于拉取公钥 https://github.com/<用户名>.keys；留空则跳过 SSH 配置）: " SSH_GITHUB_USER </dev/tty || SSH_GITHUB_USER=""
    fi
  elif [[ "$AUTO_YES" != true ]]; then
    local input=""
    read -r -p "请输入 GitHub 用户名（用于拉取公钥；回车用默认 ${SSH_GITHUB_USER}，留空并回车跳过）: " input </dev/tty || input=""
    if [[ -z "$input" ]]; then
      warn "未输入用户名，跳过 SSH 配置。"
      return 0
    fi
    SSH_GITHUB_USER="$input"
  fi

  # 未输入用户名 → 跳过 SSH（避免改了端口/禁用密码后无公钥导致无法登录）
  if [[ -z "$SSH_GITHUB_USER" ]]; then
    warn "未输入 GitHub 用户名，跳过 SSH 公钥/改端口配置。"
    return 0
  fi

  info "配置 SSH：从 GitHub($SSH_GITHUB_USER) 拉公钥，端口→$SSH_PORT，仅密钥登录"
  if $DRY_RUN; then
    echo "  (dry) 拉取 https://github.com/$SSH_GITHUB_USER.keys 并写入 authorized_keys"
    echo "  (dry) 修改 sshd: Port $SSH_PORT / PasswordAuthentication no"
    return 0
  fi

  # 4.1 拉取 GitHub 公钥（等价 key.sh 的 -g）；失败则跳过，不阻塞其他模块
  local keys_url="https://github.com/${SSH_GITHUB_USER}.keys"
  local pub_key
  if ! pub_key=$(curl -fsSL "$keys_url" 2>/dev/null) || [[ -z "$pub_key" ]]; then
    warn "无法从 ${keys_url} 拉取公钥（用户名不存在或未配置公钥）。跳过 SSH 配置（未改端口、未禁用密码）。"
    return 0
  fi

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [[ "$SSH_OVERWRITE_KEYS" == "true" ]]; then
    echo -e "${pub_key}\n" > "$HOME/.ssh/authorized_keys"      # 等价 -o
  else
    touch "$HOME/.ssh/authorized_keys"
    grep -qF "$pub_key" "$HOME/.ssh/authorized_keys" || echo -e "\n${pub_key}\n" >> "$HOME/.ssh/authorized_keys"
  fi
  chmod 600 "$HOME/.ssh/authorized_keys"
  log "SSH 公钥已写入 $HOME/.ssh/authorized_keys"

  # 4.2 修改端口 + 禁用密码（等价 key.sh 的 -p / -d）
  local conf="/etc/ssh/sshd_config"
  sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" "$conf"
  grep -q "^Port ${SSH_PORT}$" "$conf" || echo "Port ${SSH_PORT}" >> "$conf"
  if [[ "$SSH_DISABLE_PASSWORD" == "true" ]]; then
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$conf"
    sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$conf"
  fi

  # 4.3 放行新端口（配合防火墙）
  if [[ "$PKG_MANAGER" == "apt" ]] && command_exists ufw; then
    ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh'; then
    systemctl reload ssh 2>/dev/null || true
  elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd'; then
    systemctl reload sshd 2>/dev/null || true
  fi
  log "SSH 配置完成：端口 $SSH_PORT，仅密钥登录"
  warn "⚠️ 请保持当前 SSH 连接，另开一个终端用新端口 $SSH_PORT 测试登录成功后再断开！"
}

# ---------- 5. Zsh + Oh My Zsh + powerlevel10k ----------
install_zsh() {
  module_enabled zsh || return 0
  [[ "$INSTALL_ZSH" != "true" ]] && return 0
  info "安装 Zsh + Oh My Zsh + powerlevel10k（应用配置，跳过向导）..."
  if $DRY_RUN; then
    echo "  (dry) 安装 zsh / oh-my-zsh / p10k 主题 / 插件，写入 .p10k.zsh"
    return 0
  fi

  $PKG_INSTALL zsh

  # Oh My Zsh
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  fi
  local zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

  # powerlevel10k 主题
  local p10k_dir="$zsh_custom/themes/powerlevel10k"
  if [[ ! -d "$p10k_dir" ]]; then
    git clone -q --depth 1 --single-branch https://github.com/romkatv/powerlevel10k.git "$p10k_dir"
  fi

  # 需要额外 git clone 的插件（其余为 oh-my-zsh 内置）；已在 ZSH_PLUGINS 里才装
  local ext_plugins=(zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search)
  local p dir
  for p in "${ext_plugins[@]}"; do
    if [[ " $ZSH_PLUGINS " == *" $p "* ]]; then
      dir="$zsh_custom/plugins/$p"
      if [[ ! -d "$dir" ]]; then
        git clone -q --depth 1 --single-branch "https://github.com/zsh-users/${p}.git" "$dir" 2>/dev/null || warn "插件 ${p} 克隆失败，已跳过"
      fi
    fi
  done

  # .zshrc：切到 p10k 主题 + 按配置启用插件 + 跳过 p10k 向导
  local zshrc="$HOME/.zshrc"
  sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$zshrc"
  grep -q '^ZSH_THEME="powerlevel10k/powerlevel10k"' "$zshrc" || echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$zshrc"
  sed -i "s/^plugins=(.*)/plugins=(${ZSH_PLUGINS})/" "$zshrc"
  grep -q "^plugins=(${ZSH_PLUGINS})$" "$zshrc" || echo "plugins=(${ZSH_PLUGINS})" >> "$zshrc"
  # 只要存在 .p10k.zsh 就 source；且强制跳过设置向导
  grep -q 'POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD' "$zshrc" \
    || echo 'POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true' >> "$zshrc"
  grep -q 'source ~/.p10k.zsh' "$zshrc" || echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> "$zshrc"

  # 写入 p10k 配置（不走向导）
  apply_p10k_config

  chsh -s "$(command -v zsh)" "${SUDO_USER:-$USER}" 2>/dev/null || true
  log "Zsh + p10k 安装完成，已应用配置并跳过向导"
}

apply_p10k_config() {
  local dest="$HOME/.p10k.zsh"
  local bundled="${SCRIPT_DIR}/conf/p10k.zsh"

  if [[ -n "$P10K_CONFIG_URL" ]]; then
    if [[ "$P10K_CONFIG_URL" =~ ^https?:// ]]; then
      info "从 URL 拉取 p10k 配置: $P10K_CONFIG_URL"
      curl -fsSL "$P10K_CONFIG_URL" -o "$dest" || { warn "拉取失败，改用内置配置。"; use_bundled_p10k "$dest" "$bundled"; }
    elif [[ -f "$P10K_CONFIG_URL" ]]; then
      info "从本地文件复制 p10k 配置: $P10K_CONFIG_URL"
      cp "$P10K_CONFIG_URL" "$dest"
    else
      warn "P10K_CONFIG_URL 不是有效 URL 或路径，使用内置配置。"
      use_bundled_p10k "$dest" "$bundled"
    fi
  elif [[ -f "$dest" ]]; then
    info "检测到已有 ~/.p10k.zsh，保留现有配置。"
  else
    use_bundled_p10k "$dest" "$bundled"
  fi
}

# 默认应用随工具内置的 conf/p10k.zsh（即你上传的 p10k 配置）
use_bundled_p10k() {
  local dest="$1" bundled="$2"
  if [[ -f "$bundled" ]]; then
    cp "$bundled" "$dest"
    log "已应用内置 p10k 配置（conf/p10k.zsh），并跳过设置向导"
  else
    generate_default_p10k "$dest"
  fi
}

# 内置默认 p10k 配置（干净、极简，跳过向导）
generate_default_p10k() {
  local dest="$1"
  cat > "$dest" <<'P10K_EOF'
# 默认 powerlevel10k 配置 —— 由 vps-setup 生成，跳过设置向导
POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
POWERLEVEL9K_MODE=nerdfont-complete
POWERLEVEL9K_PROMPT_ON_NEWLINE=true
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(context dir vcs)
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status root_indicator background_jobs)
POWERLEVEL9K_SHORTEN_DIR_LENGTH=2
POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
P10K_EOF
  log "已生成内置默认 p10k 配置"
}

# ============================================================
#  可选：开发/安全环境
# ============================================================


# ---------------- 汇总报告 ----------------
print_summary() {
  echo
  echo "=================================================="
  echo "  ✅ vps-setup 执行完成"
  echo "=================================================="
  [[ -f "$LOG_FILE" ]] && echo "  完整日志: $LOG_FILE"
  echo "  已启用模块:"
  printf "    - %s\n" "swap / bbr / reboot(每日4点重启) / ssh(端口${SSH_PORT}) / zsh"
  echo "  已安装关键工具:"
  for cmd in git zsh; do
    if command_exists "$cmd"; then
      printf "    - %-8s %s\n" "$cmd" "$($cmd --version 2>/dev/null | head -n1)"
    fi
  done
  if swapon --show 2>/dev/null | grep -q .; then echo "    - swapfile   已启用"; fi
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")
  echo "    拥塞控制:   $cc"
  echo "=================================================="
}

# ---------------- 主流程 ----------------
main() {
  require_root "$@"
  parse_args "$@"
  detect_os
  check_environment

  # 交互式勾选菜单（默认弹出）：仅当未用 -m 指定模块、且非 --auto 全自动时显示
  if [[ "${#ONLY_MODULES[@]}" -eq 0 && "$AUTO_YES" != true ]]; then
    show_module_menu
  fi

  info "开始执行 vps-setup（dry-run=${DRY_RUN}）..."

  setup_swap
  setup_bbr
  setup_daily_reboot
  setup_ssh
  install_zsh

  print_summary
}

main "$@"
