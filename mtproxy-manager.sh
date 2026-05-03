#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MTProxy Manager"
APP_VERSION="2.0"
IMAGE_DEFAULT="telegrammessenger/proxy:latest"
CONTAINER_DEFAULT="mtproxy"
CONFIG_DIR="/etc/mtproxy-manager"
CONFIG_FILE="$CONFIG_DIR/config.env"
DATA_DIR="/var/lib/mtproxy-manager/data"
SELF_PATH="/usr/local/bin/mtproxy-manager"

if [ -t 1 ]; then
    R=$'\033[0;31m'
    G=$'\033[0;32m'
    Y=$'\033[1;33m'
    B=$'\033[0;34m'
    C=$'\033[0;36m'
    W=$'\033[1;37m'
    D=$'\033[0;90m'
    NC=$'\033[0m'
    BOLD=$'\033[1m'
else
    R='' G='' Y='' B='' C='' W='' D='' NC='' BOLD=''
fi

ok() { printf "%s ✓%s %s\n" "$G" "$NC" "$1"; }
warn() { printf "%s !%s %s\n" "$Y" "$NC" "$1"; }
err() { printf "%s x%s %s\n" "$R" "$NC" "$1" >&2; }
die() { err "$1"; exit 1; }
hdr() { printf "\n%s── %s%s%s\n" "$B" "$BOLD" "$1" "$NC"; }
pause() { [ -t 0 ] && { printf "\n%sEnter%s — continue..." "$D" "$NC"; read -r _; } || true; }
menu_i() { printf "  %2s) %-28s %s\n" "$1" "$2" "$3"; }

check_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root"
}

check_deps() {
    command -v docker >/dev/null 2>&1 || die "Docker is not installed"
    command -v curl >/dev/null 2>&1 || die "curl is not installed"
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR"
    chmod 700 "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || true
}

load_config() {
    SECRET=""
    TAG=""
    PORT="443"
    WORKERS="2"
    IMAGE="$IMAGE_DEFAULT"
    CONTAINER_NAME="$CONTAINER_DEFAULT"

    [ -f "$CONFIG_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
}

save_config() {
    ensure_dirs
    cat > "$CONFIG_FILE" <<EOF
# $APP_NAME configuration
SECRET="$SECRET"
TAG="$TAG"
PORT="$PORT"
WORKERS="$WORKERS"
IMAGE="$IMAGE"
CONTAINER_NAME="$CONTAINER_NAME"
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16 | tr 'A-F' 'a-f'
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

normalize_secret() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | tr 'A-F' 'a-f' | tr -d '[:space:]')"
    [ -n "$value" ] || { echo ""; return 0; }
    IFS=',' read -r -a parts <<< "$value"
    local p
    for p in "${parts[@]}"; do
        [[ "$p" =~ ^[0-9a-f]{32}$ ]] || return 1
    done
    printf '%s' "$value"
}

normalize_tag() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | tr 'A-F' 'a-f' | tr -d '[:space:]')"
    [ -n "$value" ] || { echo ""; return 0; }
    [[ "$value" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s' "$value"
}

get_ip() {
    curl -fsS --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || \
    curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null | tr -d '[:space:]' || true
}

container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$CONTAINER_NAME"
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$CONTAINER_NAME"
}

status_text() {
    if container_running; then
        printf "%sRunning%s" "$G" "$NC"
    elif container_exists; then
        printf "%sStopped%s" "$R" "$NC"
    else
        printf "%sNot installed%s" "$D" "$NC"
    fi
}

stats_output() {
    container_running || return 0
    docker exec "$CONTAINER_NAME" sh -lc '
        if command -v curl >/dev/null 2>&1; then
            curl -fsS http://localhost:2398/stats
        elif command -v wget >/dev/null 2>&1; then
            wget -qO- http://localhost:2398/stats
        fi
    ' 2>/dev/null || true
}

start_container() {
    load_config
    [ -n "${SECRET:-}" ] || SECRET="$(generate_secret)"
    SECRET="$(normalize_secret "$SECRET")" || die "Invalid SECRET format"
    if [ -n "${TAG:-}" ]; then
        TAG="$(normalize_tag "$TAG")" || die "Invalid TAG format"
    fi
    [ -n "${PORT:-}" ] || PORT="443"
    [ -n "${WORKERS:-}" ] || WORKERS="2"

    ensure_dirs
    save_config

    docker pull "$IMAGE" >/dev/null
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    local args=(
        -d
        --name "$CONTAINER_NAME"
        --restart unless-stopped
        -p "${PORT}:443"
        -v "${DATA_DIR}:/data"
        -e "SECRET=${SECRET}"
        -e "WORKERS=${WORKERS}"
    )
    [ -n "$TAG" ] && args+=(-e "TAG=${TAG}")

    docker run "${args[@]}" "$IMAGE" >/dev/null
    sleep 2
    container_running || { docker logs "$CONTAINER_NAME" --tail 50 2>/dev/null || true; die "Container did not start"; }
}

stop_container() {
    container_exists || return 0
    docker stop "$CONTAINER_NAME" >/dev/null
}

restart_container() {
    if container_exists; then
        docker restart "$CONTAINER_NAME" >/dev/null
    else
        start_container
    fi
}

show_links() {
    load_config
    [ -n "${SECRET:-}" ] || die "Config is missing SECRET"
    local ip; ip="$(get_ip)"
    [ -n "$ip" ] || ip="<IP>"

    printf "\n%sLinks%s\n" "$BOLD" "$NC"
    local secret
    IFS=',' read -r -a secrets <<< "$SECRET"
    for secret in "${secrets[@]}"; do
        printf "  Secret: %s\n" "${W}${secret}${NC}"
        printf "  tg://proxy?server=%s&port=%s&secret=%s\n" "$ip" "$PORT" "$secret"
        printf "  https://t.me/proxy?server=%s&port=%s&secret=%s\n" "$ip" "$PORT" "$secret"
    done
}

show_status() {
    load_config
    printf "\n%s%s%s v%s\n" "$BOLD" "$APP_NAME" "$NC" "$APP_VERSION"
    printf "  Image: %s\n" "${IMAGE:-$IMAGE_DEFAULT}"
    printf "  Container: %s\n" "${CONTAINER_NAME:-$CONTAINER_DEFAULT}"
    printf "  Port: %s\n" "${PORT:-443}"
    printf "  Workers: %s\n" "${WORKERS:-2}"
    printf "  Tag: %s\n" "${TAG:-<none>}"
    printf "  Status: "
    status_text
    printf "\n"
    local raw
    raw="$(stats_output)"
    if [ -n "$raw" ]; then
        printf "\nStats:\n%s\n" "$raw" | sed 's/^/  /'
    else
        printf "\nStats: unavailable\n"
    fi
}

show_logs() {
    local lines="${1:-50}"
    container_exists || die "Container is not installed"
    docker logs --tail "$lines" "$CONTAINER_NAME"
}

install_interactive() {
    hdr "Install"
    local secret_input tag_input port_input workers_input
    load_config
    printf "  Secret [auto-generate]: "
    read -r secret_input || true
    printf "  Tag [optional]: "
    read -r tag_input || true
    printf "  Port [${PORT:-443}]: "
    read -r port_input || true
    printf "  Workers [${WORKERS:-2}]: "
    read -r workers_input || true

    SECRET="${secret_input:-$(generate_secret)}"
    SECRET="$(normalize_secret "$SECRET")" || die "Invalid SECRET"
    TAG="${tag_input:-}"
    if [ -n "$TAG" ]; then
        TAG="$(normalize_tag "$TAG")" || die "Invalid TAG"
    else
        TAG=""
    fi
    PORT="${port_input:-${PORT:-443}}"
    WORKERS="${workers_input:-${WORKERS:-2}}"
    [[ "$PORT" =~ ^[0-9]+$ ]] || die "Invalid port"
    [[ "$WORKERS" =~ ^[0-9]+$ ]] || die "Invalid workers"
    CONTAINER_NAME="${CONTAINER_NAME:-$CONTAINER_DEFAULT}"
    IMAGE="${IMAGE:-$IMAGE_DEFAULT}"
    save_config
    start_container
    show_post_install
}

show_post_install() {
    local ip
    ip="$(get_ip)"
    [ -n "$ip" ] || ip="<IP>"
    printf "\n%s%s%s installed\n" "$G" "$APP_NAME" "$NC"
    printf "  Web stats: docker exec %s sh -lc 'curl -fsS http://localhost:2398/stats'\n" "$CONTAINER_NAME"
    show_links
    printf "  Public IP: %s\n" "$ip"
}

edit_config() {
    load_config
    ensure_dirs
    local editor="${EDITOR:-$(command -v nano || command -v vim || command -v vi || true)}"
    [ -n "$editor" ] || die "No editor found"
    "$editor" "$CONFIG_FILE"
}

set_secret() {
    load_config
    local input="${1:-}"
    [ -n "$input" ] || die "SECRET is required"
    SECRET="$(normalize_secret "$input")" || die "Invalid SECRET"
    save_config
}

set_tag() {
    load_config
    local input="${1:-}"
    if [ -z "$input" ]; then
        TAG=""
    else
        TAG="$(normalize_tag "$input")" || die "Invalid TAG"
    fi
    save_config
}

set_port() {
    load_config
    local input="${1:-}"
    [[ "$input" =~ ^[0-9]+$ ]] || die "Invalid port"
    PORT="$input"
    save_config
}

set_workers() {
    load_config
    local input="${1:-}"
    [[ "$input" =~ ^[0-9]+$ ]] || die "Invalid workers"
    WORKERS="$input"
    save_config
}

do_update() {
    load_config
    docker pull "$IMAGE" >/dev/null
    restart_container
}

do_uninstall() {
    if container_exists; then
        docker rm -f "$CONTAINER_NAME" >/dev/null || true
    fi
    rm -f "$CONFIG_FILE"
}

self_install() {
    if [ "${BASH_SOURCE[0]}" = "$SELF_PATH" ]; then
        return 0
    fi
    install -m 755 "${BASH_SOURCE[0]}" "$SELF_PATH"
    ok "Installed CLI to $SELF_PATH"
}

help_text() {
    cat <<EOF
$APP_NAME v$APP_VERSION

Usage:
  mtproxy-manager
  mtproxy-manager <command>

Commands:
  install            Install and start the proxy
  start              Start the proxy
  stop               Stop the proxy
  restart            Restart the proxy
  status             Show status and stats
  logs [N]           Show logs
  links              Show client links
  config show        Print config
  config edit        Edit config
  config secret VAL   Set secret
  config tag VAL     Set tag
  config port VAL    Set port
  config workers N   Set workers
  update             Pull latest image and restart
  uninstall          Remove container and config
  help               Show this help

Config:
  $CONFIG_FILE
  $DATA_DIR
EOF
}

menu() {
    while true; do
        load_config
        printf "\n%s%s%s v%s\n" "$BOLD" "$APP_NAME" "$NC" "$APP_VERSION"
        printf "  Status: "
        status_text
        printf "\n  Container: %s\n" "${CONTAINER_NAME:-$CONTAINER_DEFAULT}"
        printf "  Image: %s\n" "${IMAGE:-$IMAGE_DEFAULT}"
        printf "\n"
        menu_i 1 "Install" ""
        menu_i 2 "Start/Restart" ""
        menu_i 3 "Stop" ""
        menu_i 4 "Status" ""
        menu_i 5 "Logs" ""
        menu_i 6 "Links" ""
        menu_i 7 "Edit config" ""
        menu_i 8 "Update image" ""
        menu_i 9 "Uninstall" ""
        menu_i 0 "Exit" ""
        printf "\n> "
        read -r choice || exit 0
        case "$choice" in
            1) install_interactive ;;
            2) restart_container ;;
            3) stop_container ;;
            4) show_status; pause ;;
            5) show_logs 50; pause ;;
            6) show_links; pause ;;
            7) edit_config ;;
            8) do_update ;;
            9) do_uninstall ;;
            0) exit 0 ;;
            *) warn "Invalid choice" ;;
        esac
    done
}

cli() {
    local cmd="${1:-menu}"
    shift || true
    case "$cmd" in
        install) check_root; check_deps; install_interactive; self_install ;;
        start) check_root; check_deps; start_container ;;
        stop) check_root; check_deps; stop_container ;;
        restart) check_root; check_deps; restart_container ;;
        status) check_root; check_deps; show_status ;;
        logs) check_root; check_deps; show_logs "${1:-50}" ;;
        links) check_root; check_deps; show_links ;;
        config)
            check_root; check_deps
            case "${1:-show}" in
                show) load_config; [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || die "Config not found" ;;
                edit) edit_config ;;
                secret) shift || true; set_secret "${1:-}" ;;
                tag) shift || true; set_tag "${1:-}" ;;
                port) shift || true; set_port "${1:-}" ;;
                workers) shift || true; set_workers "${1:-}" ;;
                *) die "Usage: config show|edit|secret|tag|port|workers" ;;
            esac
            ;;
        update) check_root; check_deps; do_update ;;
        uninstall) check_root; check_deps; do_uninstall ;;
        help|-h|--help) help_text ;;
        menu|"") check_root; check_deps; menu ;;
        *) die "Unknown command: $cmd" ;;
    esac
}

cli "$@"
