#!/bin/bash
# 被 sh（Debian/Ubuntu 的 sh 是 dash）误调时，自动切回 bash 重新执行
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

# ============================================================
# ssh-connect —— SSH 主机管理器 + 快捷连接
# 单文件 / 免 sudo / 幂等可重跑 / Linux + Android/Termux 通用
#
# 用法：
#   ssh-connect                    交互式菜单
#   ssh-connect add [名字]         添加 / 修改主机（交互）
#   ssh-connect rm <名字>          删除主机
#   ssh-connect ls                 列出所有主机
#   ssh-connect c <名字>           SSH 连接（配了 tmux 会话就自动接入）
#   ssh-connect m <名字>           mosh 连接（弱网 / 换网不断线）
#   ssh-connect x <名字> <命令...> 远程执行命令
#   ssh-connect p <名字> <本地> <远程>  scp 传文件（-r 递归）
#   ssh-connect t <名字>           测试连通性 + 握手延迟
#   ssh-connect sync              重新生成 ssh config / 快捷命令
#   ssh-connect install           装命令 + 写 bashrc 托管块
#   ssh-connect widget <名字>     生成 Termux:Widget 一键连接小部件
#   ssh-connect export [文件]     导出主机配置（换设备用）
#   ssh-connect import <文件>     导入主机配置
#   ssh-connect path              显示数据目录
#   ssh-connect uninstall [--purge]  卸载（--purge 连配置一起删）
#
# 数据（全部本地，不进仓库）：
#   ~/.ssh-connect/hosts.tsv       主机列表（chmod 600）
#   ~/.ssh-connect/commands.sh     快捷命令（bashrc 托管块 source 它）
#   ~/.ssh/config                  生成 Host 块（托管标记之间）
#   ~/.local/bin/ssh-connect       命令本体
#   ~/.shortcuts/sshc-<名字>.sh    Termux:Widget 小部件
#
# 环境变量：
#   SSH_CONNECT_DIR        数据目录（默认 ~/.ssh-connect）
#   SSH_CONNECT_DRYRUN=1   只打印将执行的命令，不真连
# ============================================================

# ---------- 颜色 / 日志 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $1"; return 1; }

# ---------- 路径 ----------
DATA_DIR="${SSH_CONNECT_DIR:-$HOME/.ssh-connect}"
HOSTS_FILE="$DATA_DIR/hosts.tsv"
COMMANDS_FILE="$DATA_DIR/commands.sh"
SSH_CONFIG="${SSH_CONNECT_SSH_CONFIG:-$HOME/.ssh/config}"
BIN_DIR="$HOME/.local/bin"
BASHRC="$HOME/.bashrc"
MARK_BEGIN="# >>> ssh-connect >>>"
MARK_END="# <<< ssh-connect <<<"
SELF_SRC="${BASH_SOURCE[0]:-$0}"
SELF_PATH="$(cd "$(dirname "$SELF_SRC")" 2>/dev/null && pwd)/$(basename "$SELF_SRC")" || SELF_PATH="$SELF_SRC"

usage() {
    sed -n '2,40p' "$SELF_PATH" 2>/dev/null | grep -E '^\s*#\s*(ssh-connect|用法|    )' | sed 's/^#\s\?//' || true
}

# ---------- 数据文件 ----------
ensure_data() {
    mkdir -p "$DATA_DIR"
    if [ ! -f "$HOSTS_FILE" ]; then
        printf '# name\tuser\thost\tport\tidentity\textra\ttmux\n' > "$HOSTS_FILE"
    fi
    chmod 600 "$HOSTS_FILE"
}

host_names() {
    [ -f "$HOSTS_FILE" ] || return 0
    { grep -v '^#' "$HOSTS_FILE" 2>/dev/null || true; } | cut -f1
}

host_field() { # name 列号
    awk -F'\t' -v n="$1" -v i="$2" '$1==n {print $i; exit}' "$HOSTS_FILE" 2>/dev/null
}

host_exists() { [ -n "$(host_field "$1" 1)" ]; }

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }

pick_host() { # 弹编号列表供选择，选中的名字放全局 _pick
    local names=() i sel
    mapfile -t names < <(host_names | grep . || true)
    if [ ${#names[@]} -eq 0 ]; then
        warn "还没有主机，先用 add 添加一个"
        return 1
    fi
    echo "选择主机："
    for i in "${!names[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${names[$i]}"
    done
    read -rp "编号> " sel || return 1
    case "$sel" in
        ''|*[!0-9]*) fail "请输入编号"; return 1 ;;
    esac
    if [ "$sel" -lt 1 ] || [ "$sel" -gt ${#names[@]} ]; then
        fail "编号超出范围（1-${#names[@]}）"
        return 1
    fi
    _pick="${names[$((sel - 1))]}"
}

drop_host_line() { # 从 hosts.tsv 删掉指定主机行
    { grep -v "^$1"$'\t' "$HOSTS_FILE" 2>/dev/null || true; } > "$HOSTS_FILE.tmp"
    mv "$HOSTS_FILE.tmp" "$HOSTS_FILE"
    chmod 600 "$HOSTS_FILE"
}

# ---------- 增删查 ----------
add_host() {
    ensure_data
    local name="${1:-}"
    if [ -z "$name" ]; then
        read -rp "主机名（小写字母/数字/连字符，如 pc）> " name || return 0
    fi
    [ -z "$name" ] && { fail "主机名不能为空"; return 1; }
    valid_name "$name" || { fail "主机名含非法字符: $name"; return 1; }

    local user host port ident extra tmux
    host_exists "$name" && echo "（$name 已存在，下面回车可保持不变，输入新值则覆盖）"

    read -rp "登录用户 [$(id -un)]> " user || return 0
    user="${user:-$(id -un)}"
    read -rp "地址（frp 映射后的域名/IP）> " host || return 0
    [ -z "$host" ] && { fail "地址不能为空"; return 1; }
    read -rp "端口 [22]> " port || return 0
    port="${port:-22}"
    read -rp "私钥路径（回车=用默认密钥）> " ident || return 0
    read -rp "附加 ssh 选项（Key=Value;Key=Value，如 ProxyJump=bastion）> " extra || return 0
    read -rp "tmux 会话名（填了则连接后自动 tmux new -As 接入，回车=不接）> " tmux || return 0

    drop_host_line "$name"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$user" "$host" "$port" "$ident" "$extra" "$tmux" >> "$HOSTS_FILE"
    info "已保存: $name ($user@$host:$port)"
    sync_all
}

rm_host() {
    ensure_data
    local name="${1:-}"
    if [ -z "$name" ]; then
        read -rp "删哪个主机> " name || return 0
    fi
    host_exists "$name" || { fail "没有这个主机: $name"; return 1; }
    drop_host_line "$name"
    info "已删除: $name"
    sync_all
}

list_hosts() {
    ensure_data
    local rows
    rows="$( { grep -v '^#' "$HOSTS_FILE" 2>/dev/null || true; } )"
    [ -z "$rows" ] && { warn "还没有主机，选 1 添加一个"; return 0; }
    printf '%-14s %-12s %-30s %-6s %-18s %-20s %s\n' "名字" "用户" "地址" "端口" "私钥" "附加选项" "tmux"
    echo "$rows" | awk -F'\t' '{
        printf "%-14s %-12s %-30s %-6s %-18s %-20s %s\n",
            $1, $2, $3, $4, ($5==""?"-":$5), ($6==""?"-":$6), ($7==""?"-":$7)
    }'
}

# ---------- 连接 ----------
build_opts() { # name → 全局 _sc_opts 数组 + _sc_target
    local name="$1" user host port ident extra kv ifs_old
    user="$(host_field "$name" 2)"
    host="$(host_field "$name" 3)"
    port="$(host_field "$name" 4)"
    ident="$(host_field "$name" 5)"
    extra="$(host_field "$name" 6)"
    [ -z "$host" ] && { fail "找不到主机 '$name'，先用 ls 看看列表"; return 1; }
    _sc_opts=(-p "${port:-22}")
    [ -n "$ident" ] && _sc_opts+=(-i "$ident")
    if [ -n "$extra" ]; then
        ifs_old="$IFS"; IFS=';'
        for kv in $extra; do [ -n "$kv" ] && _sc_opts+=(-o "$kv"); done
        IFS="$ifs_old"
    fi
    _sc_target="${user:-$(id -un)}@$host"
}

connect_ssh() {
    local name="${1:-}"
    if [ -z "$name" ]; then pick_host || return 1; name="$_pick"; fi
    ensure_data; build_opts "$name" || return 1
    local tmux_s; tmux_s="$(host_field "$name" 7)"
    if [ "${SSH_CONNECT_DRYRUN:-0}" = "1" ]; then
        if [ -n "$tmux_s" ]; then
            echo "ssh ${_sc_opts[*]} -t $_sc_target \"tmux new -As $tmux_s\""
        else
            echo "ssh ${_sc_opts[*]} $_sc_target"
        fi
        return 0
    fi
    if [ -n "$tmux_s" ]; then
        ssh "${_sc_opts[@]}" -t "$_sc_target" "tmux new -As '$tmux_s'"
    else
        ssh "${_sc_opts[@]}" "$_sc_target"
    fi
}

connect_mosh() {
    local name="${1:-}"
    if [ -z "$name" ]; then pick_host || return 1; name="$_pick"; fi
    ensure_data; build_opts "$name" || return 1
    command -v mosh >/dev/null 2>&1 || { fail "没装 mosh：Termux 跑 pkg install mosh，Debian/Ubuntu 跑 apt install mosh"; return 1; }
    local port ident extra sshstr kv ifs_old tmux_s
    port="$(host_field "$name" 4)"; ident="$(host_field "$name" 5)"; extra="$(host_field "$name" 6)"
    tmux_s="$(host_field "$name" 7)"
    sshstr="ssh -p ${port:-22}"
    [ -n "$ident" ] && sshstr="$sshstr -i $ident"
    if [ -n "$extra" ]; then
        ifs_old="$IFS"; IFS=';'
        for kv in $extra; do [ -n "$kv" ] && sshstr="$sshstr -o $kv"; done
        IFS="$ifs_old"
    fi
    if [ "${SSH_CONNECT_DRYRUN:-0}" = "1" ]; then
        if [ -n "$tmux_s" ]; then
            echo "mosh --ssh=\"$sshstr\" $_sc_target -- tmux new -As $tmux_s"
        else
            echo "mosh --ssh=\"$sshstr\" $_sc_target"
        fi
        return 0
    fi
    if [ -n "$tmux_s" ]; then
        mosh --ssh="$sshstr" "$_sc_target" -- tmux new -As "$tmux_s"
    else
        mosh --ssh="$sshstr" "$_sc_target"
    fi
}

remote_exec() {
    local name="${1:-}"; [ $# -gt 0 ] && shift
    if [ -z "$name" ]; then pick_host || return 1; name="$_pick"; fi
    ensure_data; build_opts "$name" || return 1
    ssh "${_sc_opts[@]}" "$_sc_target" "$@"
}

push_file() {
    local name="${1:-}" src="${2:-}" dst="${3:-}"
    if [ -z "$name" ]; then pick_host || return 1; name="$_pick"; fi
    { [ -z "$src" ] || [ -z "$dst" ]; } && { fail "用法: ssh-connect p <主机名> <本地路径> <远程路径>"; return 1; }
    ensure_data; build_opts "$name" || return 1
    local port ident scpopts=()
    port="$(host_field "$name" 4)"; ident="$(host_field "$name" 5)"
    scpopts=(-P "${port:-22}")
    [ -n "$ident" ] && scpopts+=(-i "$ident")
    scp "${scpopts[@]}" -r "$src" "$_sc_target:$dst"
}

test_host() {
    local name="${1:-}"
    if [ -z "$name" ]; then pick_host || return 1; name="$_pick"; fi
    ensure_data; build_opts "$name" || return 1
    local t0 t1
    t0=$(date +%s%N)
    if ssh "${_sc_opts[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$_sc_target" true 2>/dev/null; then
        t1=$(date +%s%N)
        info "✓ $name 通，握手耗时 $(( (t1 - t0) / 1000000 )) ms"
    else
        fail "✗ $name 不通（检查地址/端口/密钥/防火墙，或先 nc -vz 地址 端口）"
        return 1
    fi
}

# ---------- 生成 ssh config / 快捷命令 / bashrc ----------
remove_managed_block() { # 文件：删掉托管标记之间的块
    local f="$1" tmp
    [ -f "$f" ] || return 0
    tmp="$(mktemp)"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$f" > "$tmp"
    mv "$tmp" "$f"
}

gen_ssh_config() {
    local dir; dir="$(dirname "$SSH_CONFIG")"
    mkdir -p "$dir"; chmod 700 "$dir"
    touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
    remove_managed_block "$SSH_CONFIG"
    # 用 awk 不用 read：read 按 tab 分割会把连续 tab（空字段）折叠掉，导致列串位
    awk -F'\t' '
        BEGIN { print "# >>> ssh-connect >>>" }
        /^#/ { next }
        NF < 3 { next }
        {
            print "Host " $1
            print "    HostName " $3
            if ($2 != "") print "    User " $2
            print "    Port " ($4 == "" ? "22" : $4)
            if ($5 != "") print "    IdentityFile " $5
            if ($6 != "") {
                n = split($6, kvs, ";")
                for (i = 1; i <= n; i++) {
                    if (kvs[i] != "") {
                        m = split(kvs[i], kv, "=")
                        print "    " kv[1] " " (m > 1 ? kv[2] : "")
                    }
                }
            }
            print ""
        }
        END { print "# <<< ssh-connect <<<" }
    ' "$HOSTS_FILE" >> "$SSH_CONFIG"
}

gen_commands() {
    local tmp; tmp="$(mktemp)"
    sed "s|__DATA_DIR__|$DATA_DIR|g" <<'EOF' > "$tmp"
# ssh-connect 快捷命令 —— 由 ssh-connect.sh 生成，请勿手改
# 改主机请用 ssh-connect add / rm，改完自动重新生成
_SSH_CONNECT_TSV="__DATA_DIR__/hosts.tsv"

_ssh_connect_field() {
    awk -F'\t' -v n="$1" -v i="$2" '$1==n {print $i; exit}' "$_SSH_CONNECT_TSV" 2>/dev/null
}

_ssh_connect_names() {
    [ -f "$_SSH_CONNECT_TSV" ] || return 0
    { grep -v '^#' "$_SSH_CONNECT_TSV" 2>/dev/null || true; } | cut -f1
    return 0
}

_ssh_connect_pick() { # 弹编号列表，选中的名字放全局 _sc_pick
    local names=() i sel
    mapfile -t names < <(_ssh_connect_names | grep . || true)
    if [ ${#names[@]} -eq 0 ]; then
        echo "ssh-connect: 还没有主机，用 ssh-connect add 添加" >&2
        return 1
    fi
    echo "选择主机："
    for i in "${!names[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${names[$i]}"
    done
    read -rp "编号> " sel || return 1
    case "$sel" in
        ''|*[!0-9]*) echo "ssh-connect: 请输入编号" >&2; return 1 ;;
    esac
    if [ "$sel" -lt 1 ] || [ "$sel" -gt ${#names[@]} ]; then
        echo "ssh-connect: 编号超出范围（1-${#names[@]}）" >&2
        return 1
    fi
    _sc_pick="${names[$((sel - 1))]}"
}

_ssh_connect_opts() { # name → 全局 _sc_opts + _sc_target
    local name="$1" user host port ident extra kv ifs_old
    user="$(_ssh_connect_field "$name" 2)"
    host="$(_ssh_connect_field "$name" 3)"
    port="$(_ssh_connect_field "$name" 4)"
    ident="$(_ssh_connect_field "$name" 5)"
    extra="$(_ssh_connect_field "$name" 6)"
    if [ -z "$host" ]; then
        echo "ssh-connect: 找不到主机 '$name'，sshl 看列表" >&2
        return 1
    fi
    _sc_opts=(-p "${port:-22}")
    [ -n "$ident" ] && _sc_opts+=(-i "$ident")
    if [ -n "$extra" ]; then
        ifs_old="$IFS"; IFS=';'
        for kv in $extra; do [ -n "$kv" ] && _sc_opts+=(-o "$kv"); done
        IFS="$ifs_old"
    fi
    _sc_target="${user:-$(id -un)}@$host"
}

sshl() { # 列出所有主机
    local rows
    rows="$( { grep -v '^#' "$_SSH_CONNECT_TSV" 2>/dev/null || true; } )"
    [ -z "$rows" ] && { echo "（还没有主机，用 ssh-connect add 添加）"; return 0; }
    printf '%-14s %-12s %-30s %-6s %-18s %s\n' "名字" "用户" "地址" "端口" "私钥" "tmux"
    echo "$rows" | awk -F'\t' '{
        printf "%-14s %-12s %-30s %-6s %-18s %s\n",
            $1, $2, $3, $4, ($5==""?"-":$5), ($7==""?"-":$7)
    }'
}

sshc() { # SSH 连接，配了 tmux 会话就自动接入；不带参数弹列表选
    local name="${1:-}"
    if [ -z "$name" ]; then _ssh_connect_pick || return 1; name="$_sc_pick"; fi
    _ssh_connect_opts "$name" || return 1
    local tmux_s; tmux_s="$(_ssh_connect_field "$name" 7)"
    if [ "${SSH_CONNECT_DRYRUN:-0}" = "1" ]; then
        if [ -n "$tmux_s" ]; then
            echo "ssh ${_sc_opts[*]} -t $_sc_target \"tmux new -As $tmux_s\""
        else
            echo "ssh ${_sc_opts[*]} $_sc_target"
        fi
        return 0
    fi
    if [ -n "$tmux_s" ]; then
        ssh "${_sc_opts[@]}" -t "$_sc_target" "tmux new -As '$tmux_s'"
    else
        ssh "${_sc_opts[@]}" "$_sc_target"
    fi
}

sshm() { # mosh 连接，弱网/换基站不断线；不带参数弹列表选
    local name="${1:-}"
    if [ -z "$name" ]; then _ssh_connect_pick || return 1; name="$_sc_pick"; fi
    _ssh_connect_opts "$name" || return 1
    command -v mosh >/dev/null 2>&1 || { echo "没装 mosh：pkg install mosh" >&2; return 1; }
    local port ident extra sshstr kv ifs_old tmux_s
    port="$(_ssh_connect_field "$name" 4)"
    ident="$(_ssh_connect_field "$name" 5)"
    extra="$(_ssh_connect_field "$name" 6)"
    tmux_s="$(_ssh_connect_field "$name" 7)"
    sshstr="ssh -p ${port:-22}"
    [ -n "$ident" ] && sshstr="$sshstr -i $ident"
    if [ -n "$extra" ]; then
        ifs_old="$IFS"; IFS=';'
        for kv in $extra; do [ -n "$kv" ] && sshstr="$sshstr -o $kv"; done
        IFS="$ifs_old"
    fi
    if [ -n "$tmux_s" ]; then
        mosh --ssh="$sshstr" "$_sc_target" -- tmux new -As "$tmux_s"
    else
        mosh --ssh="$sshstr" "$_sc_target"
    fi
}

sshx() { # 远程执行命令: sshx <名字> uptime；不带参数弹列表选
    local name="${1:-}"; [ $# -gt 0 ] && shift
    if [ -z "$name" ]; then _ssh_connect_pick || return 1; name="$_sc_pick"; fi
    _ssh_connect_opts "$name" || return 1
    ssh "${_sc_opts[@]}" "$_sc_target" "$@"
}

scpc() { # 传文件: scpc <名字> <本地> <远程>；不带参数弹列表选
    local name="${1:-}" src="${2:-}" dst="${3:-}"
    if [ -z "$name" ]; then _ssh_connect_pick || return 1; name="$_sc_pick"; fi
    { [ -z "$src" ] || [ -z "$dst" ]; } && { echo "用法: scpc <主机名> <本地路径> <远程路径>"; return 1; }
    _ssh_connect_opts "$name" || return 1
    local port ident scpopts=()
    port="$(_ssh_connect_field "$name" 4)"; ident="$(_ssh_connect_field "$name" 5)"
    scpopts=(-P "${port:-22}")
    [ -n "$ident" ] && scpopts+=(-i "$ident")
    scp "${scpopts[@]}" -r "$src" "$_sc_target:$dst"
}

ssht() { # 测连通 + 握手延迟；不带参数弹列表选
    local name="${1:-}"
    if [ -z "$name" ]; then _ssh_connect_pick || return 1; name="$_sc_pick"; fi
    _ssh_connect_opts "$name" || return 1
    local t0 t1
    t0=$(date +%s%N)
    if ssh "${_sc_opts[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$_sc_target" true 2>/dev/null; then
        t1=$(date +%s%N)
        echo "✓ $name 通，握手 $(( (t1 - t0) / 1000000 )) ms"
    else
        echo "✗ $name 不通（地址/端口/密钥/防火墙）" >&2
        return 1
    fi
}

# 主机名补全（输 sshc pc<Tab>）
_ssh_connect_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( $(compgen -W "$(_ssh_connect_names | tr '\n' ' ')" -- "$cur") )
}
complete -F _ssh_connect_complete sshc sshm sshx scpc ssht 2>/dev/null || true
EOF
    mv "$tmp" "$COMMANDS_FILE"
    chmod 600 "$COMMANDS_FILE"
}

bashrc_block() {
    sed "s|__DATA_DIR__|$DATA_DIR|g" <<'EOF'
# >>> ssh-connect >>>
# ssh-connect 快捷命令（由 ssh-connect.sh 维护，勿手改）
[ -f "__DATA_DIR__/commands.sh" ] && . "__DATA_DIR__/commands.sh"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< ssh-connect <<<
EOF
}

ensure_bashrc_block() {
    touch "$BASHRC"
    remove_managed_block "$BASHRC"
    bashrc_block >> "$BASHRC"
}

sync_all() {
    ensure_data
    gen_ssh_config
    gen_commands
    info "已同步: $SSH_CONFIG + $COMMANDS_FILE"
}

# ---------- 安装 / 卸载 ----------
install_cmd() {
    ensure_data
    if [ ! -f "$SELF_PATH" ]; then
        fail "找不到脚本本体（可能是 curl 管道运行的）。先下载再 install："
        echo "  curl -fsSL -o ssh-connect.sh https://raw.githubusercontent.com/lggyx/ssh-connect/main/ssh-connect.sh"
        echo "  bash ssh-connect.sh install"
        return 1
    fi
    mkdir -p "$BIN_DIR"
    cp "$SELF_PATH" "$BIN_DIR/ssh-connect"
    chmod +x "$BIN_DIR/ssh-connect"
    ensure_bashrc_block
    sync_all
    info "命令已装到 $BIN_DIR/ssh-connect"
    info "bashrc 托管块已写入 $BASHRC"
    echo ""
    echo "接下来："
    echo "  1) source ~/.bashrc      （或直接新开一个终端）"
    echo "  2) ssh-connect ls        （看主机列表）"
    echo "  3) sshc <主机名>         （一键连接）"
}

uninstall_all() {
    local purge="${1:-}"
    [ -f "$BASHRC" ] && cp "$BASHRC" "$BASHRC.ssh-connect.bak"
    [ -f "$SSH_CONFIG" ] && cp "$SSH_CONFIG" "$SSH_CONFIG.ssh-connect.bak"
    remove_managed_block "$BASHRC"
    remove_managed_block "$SSH_CONFIG"
    rm -f "$BIN_DIR/ssh-connect"
    info "已移除: bashrc 托管块、ssh config 托管块、$BIN_DIR/ssh-connect（原文件留了 .ssh-connect.bak）"
    if [ "$purge" = "--purge" ]; then
        rm -rf "$DATA_DIR"
        warn "主机配置已全部删除（$DATA_DIR）"
    else
        info "主机配置保留在 $DATA_DIR（要真删加 --purge）"
    fi
}

# ---------- Termux 小部件 ----------
make_widget() {
    local name="${1:-}"
    [ -z "$name" ] && { read -rp "给哪个主机做小部件> " name || return 0; }
    ensure_data
    host_exists "$name" || { fail "没有这个主机: $name"; return 1; }
    local wdir="$HOME/.shortcuts" cmd shebang="#!/usr/bin/env bash"
    mkdir -p "$wdir"
    if [ -x /data/data/com.termux/files/usr/bin/bash ]; then
        shebang="#!/data/data/com.termux/files/usr/bin/bash"
    fi
    if [ -x "$BIN_DIR/ssh-connect" ]; then cmd="$BIN_DIR/ssh-connect"; else cmd="$SELF_PATH"; fi
    printf '%s\n' "$shebang" > "$wdir/sshc-$name.sh"
    cat >> "$wdir/sshc-$name.sh" <<EOF
# ssh-connect 小部件：一键连接 $name（需要 Termux:Widget 应用）
exec "$cmd" c "$name"
EOF
    chmod +x "$wdir/sshc-$name.sh"
    info "已生成 $wdir/sshc-$name.sh"
    echo "  手机桌面添加 Termux:Widget 小部件，点 sshc-$name 即开终端"
}

# ---------- 导出 / 导入 ----------
export_hosts() {
    local out="${1:-}"
    ensure_data
    if [ -n "$out" ]; then
        { grep -v '^#' "$HOSTS_FILE" 2>/dev/null || true; } > "$out"
        info "已导出到 $out（含主机地址信息，注意保管，别提交到公开仓库）"
    else
        { grep -v '^#' "$HOSTS_FILE" 2>/dev/null || true; }
    fi
}

import_hosts() {
    local src="${1:-}"
    [ -z "$src" ] && { fail "用法: ssh-connect import <文件>"; return 1; }
    [ -f "$src" ] || { fail "文件不存在: $src"; return 1; }
    ensure_data
    local line name
    # || [ -n "$line" ]：兼容最后一行没有换行符的文件（read 到 EOF 会返回非零）
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        name="$(printf '%s' "$line" | cut -f1)"
        valid_name "$name" || continue
        drop_host_line "$name"
        printf '%s\n' "$line" >> "$HOSTS_FILE"
    done < "$src"
    chmod 600 "$HOSTS_FILE"
    info "导入完成"
    sync_all
}

# ---------- 菜单 ----------
main_menu() {
    while :; do
        echo ""
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${CYAN}  ssh-connect（SSH 主机管理 · 快捷连接）${NC}"
        echo -e "${CYAN}=============================================${NC}"
        echo "  1) 添加 / 修改主机"
        echo "  2) 删除主机"
        echo "  3) 查看所有主机"
        echo "  4) 连接主机（SSH，自动接 tmux）"
        echo "  5) Mosh 连接（弱网 / 换网不断线）"
        echo "  6) 测试连通性"
        echo "  7) 安装命令 + 快捷方式（install）"
        echo "  8) 生成 Termux 小部件（桌面一键连接）"
        echo "  9) 导出 / 导入配置"
        echo "  10) 卸载"
        echo "  0) 退出"
        local n=""
        n="$(host_names | grep -c . || true)"
        echo -e "  状态: ${n} 个主机 · 数据在 $DATA_DIR"
        echo -e "${CYAN}---------------------------------------------${NC}"
        local ch=""
        read -rp "选择> " ch || exit 0
        local pick="" f="" act=""
        case "$ch" in
            1) add_host || true ;;
            2) rm_host || true ;;
            3) list_hosts || true ;;
            4) pick_host && connect_ssh "$_pick" || true ;;
            5) pick_host && connect_mosh "$_pick" || true ;;
            6) pick_host && test_host "$_pick" || true ;;
            7) install_cmd || true ;;
            8) make_widget || true ;;
            9) read -rp "e=导出 / i=导入 > " act || true
               case "$act" in
                   e) read -rp "导出到文件（回车=打印到屏幕）> " f || true
                      export_hosts "${f:-}" || true ;;
                   i) read -rp "从哪个文件导入> " f || true
                      [ -n "${f:-}" ] && import_hosts "$f" || true ;;
               esac ;;
            10) read -rp "连配置一起删？输入 --purge，回车=保留配置> " pick || true
                uninstall_all "${pick:-}" || true ;;
            0|q|Q) exit 0 ;;
            *) ;;
        esac
    done
}

# ---------- 入口 ----------
case "${1:-menu}" in
    add)        shift; add_host "${1:-}" ;;
    rm|del)     shift; rm_host "${1:-}" ;;
    ls|list)    list_hosts ;;
    c|connect)  shift; connect_ssh "${1:-}" ;;
    m|mosh)     shift; connect_mosh "${1:-}" ;;
    x)          shift; remote_exec "${1:-}" "$@" ;;
    p|push)     shift; push_file "${1:-}" "${2:-}" "${3:-}" ;;
    t|test)     shift; test_host "${1:-}" ;;
    sync)       sync_all ;;
    install)    install_cmd ;;
    widget)     shift; make_widget "${1:-}" ;;
    export)     shift; export_hosts "${1:-}" ;;
    import)     shift; import_hosts "${1:-}" ;;
    path)       echo "$DATA_DIR" ;;
    uninstall)  shift; uninstall_all "${1:-}" ;;
    menu|"")    main_menu ;;
    -h|--help|help) usage ;;
    *)          fail "未知命令: $1"; usage; exit 1 ;;
esac
