#!/usr/bin/env bash
#
# PasarGuard Panel — Ubuntu 22.04 Server Optimizer
#
# Tunes an Ubuntu 22.04 host that runs the PasarGuard panel (FastAPI/uvicorn +
# PostgreSQL/MySQL + NATS + node-bridge gRPC) for large deployments — hundreds
# of thousands of users on a single mid-size VPS.
#
# Every change is backed up before it is written, every module can be skipped,
# and `--rollback` restores the previous state from the backup manifest.
#
#   sudo ./scripts/optimizer.sh --check          # read-only diagnostics
#   sudo ./scripts/optimizer.sh --dry-run        # show what would change
#   sudo ./scripts/optimizer.sh                  # apply
#   sudo ./scripts/optimizer.sh --rollback latest
#
# Docs: scripts/OPTIMIZER.md

set -Eeuo pipefail

readonly OPTIMIZER_VERSION="1.0.0"
readonly STATE_DIR="/var/lib/pasarguard-optimizer"
readonly BACKUP_ROOT="${STATE_DIR}/backups"
readonly REPORT_DIR="${STATE_DIR}/reports"
readonly LOG_FILE="/var/log/pasarguard-optimizer.log"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
readonly RUN_ID

BACKUP_DIR="${BACKUP_ROOT}/${RUN_ID}"
MANIFEST="${BACKUP_DIR}/manifest.tsv"

readonly ALL_MODULES="sysctl limits thp swap io cpu nic docker journald database nginx services env"

# ---- runtime options -------------------------------------------------------
PROFILE="panel"              # panel | node | all-in-one
MODE="apply"                 # apply | check | rollback
DRY_RUN=0
ASSUME_YES=0
RESTART_SERVICES=0
APPLY_ENV=0
DB_DURABILITY="balanced"     # balanced | strict
ROLLBACK_TARGET="latest"
ONLY_MODULES=""
SKIP_MODULES=""
ENV_FILE=""
CONNTRACK_MAX_OVERRIDE=""
WORKERS_OVERRIDE=""
CREATE_SWAP=1

# ---- detected facts --------------------------------------------------------
CPU_CORES=1
RAM_MB=1024
RAM_KB=1048576
VIRT_TYPE="none"
PRIMARY_NIC=""
IS_SSD=1
DB_FLAVOR="unknown"          # postgresql | mysql | sqlite | unknown
PG_VERSION=""
PG_CONFDIR=""
PG_IN_DOCKER=0
MYSQL_CONFDIR=""
NATS_REACHABLE=0
PANEL_DIR=""

CHANGED_COUNT=0
SKIPPED_COUNT=0
declare -a NEEDS_RESTART=()
declare -a WARNINGS=()
declare -a NOTES=()

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

_log_raw() {
    # Best-effort file log; never fail the run because the log is unwritable.
    [[ -n "${LOG_FILE}" ]] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

info()    { printf '%s\n' "$*"; _log_raw "[info] $*"; }
step()    { printf '%s→%s %s\n' "${C_CYAN}" "${C_RESET}" "$*"; _log_raw "[step] $*"; }
ok()      { printf '  %s✔%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; _log_raw "[ok] $*"; }
skip()    { printf '  %s·%s %s\n' "${C_DIM}" "${C_RESET}" "${C_DIM}$*${C_RESET}"; _log_raw "[skip] $*"; }
warn()    { printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; _log_raw "[warn] $*"; WARNINGS+=("$*"); }
err()     { printf '%sERROR:%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; _log_raw "[error] $*"; }
note()    { NOTES+=("$*"); }

heading() {
    printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"
    printf '%s%s%s\n' "${C_DIM}" "$(printf '─%.0s' $(seq 1 60))" "${C_RESET}"
}

die() { err "$*"; exit 1; }

ERROR_REPORTED=0
on_error() {
    local line=$1
    (( ERROR_REPORTED )) && return 0
    ERROR_REPORTED=1
    err "aborted at line ${line}"
    if [[ -f "${MANIFEST}" ]]; then
        err "Files already changed in this run are backed up in ${BACKUP_DIR}"
        err "Restore them with: $0 --rollback ${RUN_ID}"
    fi
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

is_enabled() {
    # is_enabled <module>
    local m=$1
    if [[ -n "${ONLY_MODULES}" ]]; then
        [[ ",${ONLY_MODULES}," == *",${m},"* ]] || return 1
    fi
    [[ ",${SKIP_MODULES}," != *",${m},"* ]] || return 1
    return 0
}

confirm() {
    # confirm <prompt> — returns 0 on yes
    local prompt=$1
    (( ASSUME_YES )) && return 0
    [[ -t 0 ]] || return 1
    local reply
    read -r -p "${prompt} [y/N] " reply || return 1
    [[ "${reply}" =~ ^[Yy]$ ]]
}

need_restart() {
    local svc=$1
    local existing
    for existing in "${NEEDS_RESTART[@]:-}"; do
        [[ "${existing}" == "${svc}" ]] && return 0
    done
    NEEDS_RESTART+=("${svc}")
}

# backup_file <path> — copy into the run's backup dir and record it
backup_file() {
    local path=$1
    mkdir -p "${BACKUP_DIR}"
    [[ -f "${MANIFEST}" ]] || printf '# path\tbackup\texisted\n' >"${MANIFEST}"

    # Record each path only once per run, so rollback restores the pre-run state.
    if awk -F'\t' -v p="${path}" '$1 == p { found = 1 } END { exit !found }' "${MANIFEST}"; then
        return 0
    fi

    if [[ -e "${path}" ]]; then
        local rel="${path#/}"
        local dest="${BACKUP_DIR}/files/${rel}"
        mkdir -p "$(dirname "${dest}")"
        cp -a "${path}" "${dest}"
        printf '%s\t%s\t1\n' "${path}" "files/${rel}" >>"${MANIFEST}"
    else
        printf '%s\t%s\t0\n' "${path}" "-" >>"${MANIFEST}"
    fi
}

# write_file <path> [mode] — content on stdin; idempotent, backed up, dry-run aware
write_file() {
    local path=$1 mode=${2:-0644}
    local tmp
    tmp="$(mktemp)"
    cat >"${tmp}"

    if [[ -f "${path}" ]] && cmp -s "${tmp}" "${path}"; then
        rm -f "${tmp}"
        skip "${path} already up to date"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
    fi

    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s would write %s\n' "${C_YELLOW}" "${C_RESET}" "${path}"
        if [[ -f "${path}" ]] && has_cmd diff; then
            diff -u "${path}" "${tmp}" | sed 's/^/      /' || true
        fi
        rm -f "${tmp}"
        return 0
    fi

    backup_file "${path}"
    mkdir -p "$(dirname "${path}")"
    cat "${tmp}" >"${path}"
    chmod "${mode}" "${path}"
    rm -f "${tmp}"
    ok "wrote ${path}"
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
}

# run_cmd <description> <cmd...> — dry-run aware, non-fatal
run_cmd() {
    local desc=$1; shift
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s %s\n' "${C_YELLOW}" "${C_RESET}" "${desc}"
        return 0
    fi
    if "$@" >/dev/null 2>&1; then
        ok "${desc}"
        return 0
    fi
    warn "${desc} — failed (non-fatal)"
    return 0
}

# write_sysfs <value> <path> — volatile kernel knobs, tolerated failures
write_sysfs() {
    local value=$1 path=$2
    [[ -w "${path}" ]] || return 0
    (( DRY_RUN )) && { printf '  %s[dry-run]%s %s <- %s\n' "${C_YELLOW}" "${C_RESET}" "${path}" "${value}"; return 0; }
    printf '%s' "${value}" >"${path}" 2>/dev/null || true
}

sysctl_supported() {
    sysctl -n "$1" >/dev/null 2>&1
}

human_mb() {
    local mb=$1
    if (( mb >= 1024 )); then
        printf '%sGB' "$(awk -v m="${mb}" 'BEGIN{printf "%.1f", m/1024}')"
    else
        printf '%sMB' "${mb}"
    fi
}

# ---------------------------------------------------------------------------
# usage / arguments
# ---------------------------------------------------------------------------
usage() {
    cat <<USAGE
PasarGuard Server Optimizer v${OPTIMIZER_VERSION} — Ubuntu 22.04

Usage: sudo $0 [options]

Modes
  (default)                 Apply the tuning for the selected profile.
  --check                   Read-only health report. Changes nothing.
  --dry-run                 Show every change (with diffs) without writing.
  --rollback [ID|latest]    Restore files saved by a previous run.
  --list-backups            Show available rollback points.

Options
  --profile <p>             panel (default) | node | all-in-one
                            panel: API/DB host. node: Xray forwarding host.
                            all-in-one: panel and Xray on the same box.
  --only <m1,m2>            Run only these modules.
  --skip <m1,m2>            Run everything except these modules.
  --env-file <path>         PasarGuard .env to read/tune (auto-detected).
  --apply-env               Also patch the panel .env (backed up first).
  --db-durability <mode>    balanced (default) | strict
                            balanced sets synchronous_commit=off: a hard crash
                            can lose the last ~1s of usage counters, never
                            corrupting data. strict keeps full durability.
  --conntrack-max <n>       Override the computed conntrack table size.
  --workers <n>             Override the recommended UVICORN_WORKERS.
  --no-swap                 Never create a swap file.
  --restart-services        Restart affected services when done.
  -y, --yes                 Assume yes for prompts.
  -h, --help                This help.
  -V, --version             Print version.

Modules: ${ALL_MODULES}
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)         PROFILE="${2:?--profile needs a value}"; shift 2 ;;
            --profile=*)       PROFILE="${1#*=}"; shift ;;
            --only)            ONLY_MODULES="${2:?--only needs a value}"; shift 2 ;;
            --only=*)          ONLY_MODULES="${1#*=}"; shift ;;
            --skip)            SKIP_MODULES="${2:?--skip needs a value}"; shift 2 ;;
            --skip=*)          SKIP_MODULES="${1#*=}"; shift ;;
            --env-file)        ENV_FILE="${2:?--env-file needs a value}"; shift 2 ;;
            --env-file=*)      ENV_FILE="${1#*=}"; shift ;;
            --db-durability)   DB_DURABILITY="${2:?--db-durability needs a value}"; shift 2 ;;
            --db-durability=*) DB_DURABILITY="${1#*=}"; shift ;;
            --conntrack-max)   CONNTRACK_MAX_OVERRIDE="${2:?--conntrack-max needs a value}"; shift 2 ;;
            --conntrack-max=*) CONNTRACK_MAX_OVERRIDE="${1#*=}"; shift ;;
            --workers)         WORKERS_OVERRIDE="${2:?--workers needs a value}"; shift 2 ;;
            --workers=*)       WORKERS_OVERRIDE="${1#*=}"; shift ;;
            --apply-env)       APPLY_ENV=1; shift ;;
            --restart-services) RESTART_SERVICES=1; shift ;;
            --no-swap)         CREATE_SWAP=0; shift ;;
            --dry-run)         DRY_RUN=1; shift ;;
            --check)           MODE="check"; shift ;;
            --list-backups)    MODE="list-backups"; shift ;;
            --rollback)
                MODE="rollback"
                if [[ $# -ge 2 && "$2" != -* ]]; then ROLLBACK_TARGET="$2"; shift 2; else shift; fi
                ;;
            --rollback=*)      MODE="rollback"; ROLLBACK_TARGET="${1#*=}"; shift ;;
            -y|--yes)          ASSUME_YES=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            -V|--version)      printf '%s\n' "${OPTIMIZER_VERSION}"; exit 0 ;;
            *)                 usage >&2; die "unknown option: $1" ;;
        esac
    done

    case "${PROFILE}" in
        panel|node|all-in-one) ;;
        *) die "invalid --profile '${PROFILE}' (panel|node|all-in-one)" ;;
    esac
    case "${DB_DURABILITY}" in
        balanced|strict) ;;
        *) die "invalid --db-durability '${DB_DURABILITY}' (balanced|strict)" ;;
    esac

    local m
    for m in ${ONLY_MODULES//,/ } ${SKIP_MODULES//,/ }; do
        [[ " ${ALL_MODULES} " == *" ${m} "* ]] || die "unknown module '${m}' (valid: ${ALL_MODULES})"
    done
    if [[ -n "${CONNTRACK_MAX_OVERRIDE}" && ! "${CONNTRACK_MAX_OVERRIDE}" =~ ^[0-9]+$ ]]; then
        die "--conntrack-max must be a number"
    fi
    if [[ -n "${WORKERS_OVERRIDE}" && ! "${WORKERS_OVERRIDE}" =~ ^[0-9]+$ ]]; then
        die "--workers must be a number"
    fi
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "must run as root (use sudo)"
}

check_os() {
    local id="" ver=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id="$(. /etc/os-release && printf '%s' "${ID:-}")"
        ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    fi
    if [[ "${id}" != "ubuntu" ]]; then
        warn "designed for Ubuntu 22.04; detected '${id:-unknown} ${ver:-}'. Continuing."
        return 0
    fi
    if [[ "${ver}" != "22.04" ]]; then
        warn "tested on Ubuntu 22.04; detected ${ver}. Values still apply, verify after."
    fi
}

# ---------------------------------------------------------------------------
# detection
# ---------------------------------------------------------------------------
detect_hardware() {
    CPU_CORES="$(nproc 2>/dev/null || echo 1)"
    RAM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    RAM_MB=$(( RAM_KB / 1024 ))
    VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"

    if has_cmd ip; then
        PRIMARY_NIC="$( { ip -4 route show default 2>/dev/null || true; } | awk '/default/ {print $5; exit}')"
        [[ -n "${PRIMARY_NIC}" ]] || \
            PRIMARY_NIC="$( { ip -6 route show default 2>/dev/null || true; } | awk '/default/ {print $5; exit}')"
    fi
    if [[ -z "${PRIMARY_NIC}" ]]; then
        # Fall back to the first non-loopback, non-virtual interface that is up.
        local cand
        for cand in /sys/class/net/*; do
            local name; name="$(basename "${cand}")"
            [[ "${name}" == "lo" ]] && continue
            [[ -e "${cand}/device" ]] || continue
            [[ "$(cat "${cand}/operstate" 2>/dev/null)" == "up" ]] || continue
            PRIMARY_NIC="${name}"
            break
        done
    fi

    local root_src root_dev
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    root_dev="$( { lsblk -no PKNAME "${root_src}" 2>/dev/null || true; } | head -n1)"
    if [[ -z "${root_dev}" ]]; then
        root_dev="$(basename "${root_src:-sda}" 2>/dev/null | sed 's/[0-9]*$//' || true)"
    fi
    if [[ -r "/sys/block/${root_dev}/queue/rotational" ]]; then
        [[ "$(cat "/sys/block/${root_dev}/queue/rotational")" == "0" ]] && IS_SSD=1 || IS_SSD=0
    fi
}

detect_panel() {
    local candidates=(/opt/pasarguard /var/lib/pasarguard /opt/PasarGuard /root/pasarguard)
    local dir
    if [[ -n "${ENV_FILE}" ]]; then
        [[ -r "${ENV_FILE}" ]] || die "--env-file '${ENV_FILE}' is not readable"
        PANEL_DIR="$(dirname "${ENV_FILE}")"
        return 0
    fi
    for dir in "${candidates[@]}"; do
        if [[ -r "${dir}/.env" ]]; then
            PANEL_DIR="${dir}"
            ENV_FILE="${dir}/.env"
            return 0
        fi
    done
    for dir in "${candidates[@]}"; do
        if [[ -d "${dir}" ]]; then
            PANEL_DIR="${dir}"
            return 0
        fi
    done
}

env_get() {
    # env_get <KEY> — value from the panel .env, quotes and spaces stripped
    local key=$1
    [[ -n "${ENV_FILE}" && -r "${ENV_FILE}" ]] || return 1
    local line
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${ENV_FILE}" 2>/dev/null | tail -n1 || true)"
    [[ -n "${line}" ]] || return 1
    line="${line#*=}"
    line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")"
    printf '%s' "${line}"
}

detect_database() {
    local url=""
    url="$(env_get SQLALCHEMY_DATABASE_URL || true)"

    case "${url}" in
        postgresql*) DB_FLAVOR="postgresql" ;;
        mysql*|mariadb*) DB_FLAVOR="mysql" ;;
        sqlite*) DB_FLAVOR="sqlite" ;;
        *) DB_FLAVOR="unknown" ;;
    esac

    # Fall back to what is actually installed on the host.
    local pgconf
    pgconf="$(ls -d /etc/postgresql/*/main 2>/dev/null | sort -V | tail -n1 || true)"
    if [[ -n "${pgconf}" ]]; then
        PG_CONFDIR="${pgconf}"
        PG_VERSION="$(basename "$(dirname "${pgconf}")")"
        [[ "${DB_FLAVOR}" == "unknown" ]] && DB_FLAVOR="postgresql"
    elif has_cmd docker && docker ps --format '{{.Image}}' 2>/dev/null | grep -qiE '(postgres|timescale)'; then
        PG_IN_DOCKER=1
        [[ "${DB_FLAVOR}" == "unknown" ]] && DB_FLAVOR="postgresql"
    fi

    if [[ -d /etc/mysql/conf.d ]]; then
        MYSQL_CONFDIR="/etc/mysql/conf.d"
    elif [[ -d /etc/mysql/mariadb.conf.d ]]; then
        MYSQL_CONFDIR="/etc/mysql/mariadb.conf.d"
    fi
}

detect_nats() {
    local url host port
    url="$(env_get NATS_URL || printf 'nats://127.0.0.1:4222')"
    host="$(printf '%s' "${url}" | sed -e 's#^nats://##' -e 's#/.*##' -e 's#:.*##')"
    port="$(printf '%s' "${url}" | sed -e 's#^nats://##' -e 's#/.*##' | awk -F: '{print ($2 == "" ? 4222 : $2)}')"
    [[ -n "${host}" ]] || host="127.0.0.1"
    # "nats" is the compose service name; from the host it resolves to localhost.
    [[ "${host}" == "nats" ]] && host="127.0.0.1"

    if has_cmd nc && nc -z -w2 "${host}" "${port}" >/dev/null 2>&1; then
        NATS_REACHABLE=1
    elif (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
        NATS_REACHABLE=1
    fi
}

# ---------------------------------------------------------------------------
# module: sysctl
# ---------------------------------------------------------------------------
compute_conntrack_max() {
    if [[ -n "${CONNTRACK_MAX_OVERRIDE}" ]]; then
        printf '%s' "${CONNTRACK_MAX_OVERRIDE}"
        return 0
    fi
    # Kernel rule of thumb on x86_64: RAM_bytes / 16384 / 2. Each entry costs
    # roughly 320 B, so 1M entries ≈ 320 MB of unswappable kernel memory.
    local base=$(( RAM_KB / 32 ))
    case "${PROFILE}" in
        node|all-in-one) base=$(( base * 2 )) ;;
    esac
    base=$(( base / 65536 * 65536 ))
    (( base < 262144 )) && base=262144
    (( base > 4194304 )) && base=4194304
    printf '%s' "${base}"
}

module_sysctl() {
    heading "Kernel / network tuning (sysctl)"

    local conf="/etc/sysctl.d/99-pasarguard-optimizer.conf"
    local page_kb=4
    page_kb=$(( $(getconf PAGE_SIZE 2>/dev/null || echo 4096) / 1024 ))
    (( page_kb > 0 )) || page_kb=4
    local total_pages=$(( RAM_KB / page_kb ))

    local tcp_low=$(( total_pages * 6 / 100 ))
    local tcp_pressure=$(( total_pages * 8 / 100 ))
    local tcp_max=$(( total_pages * 12 / 100 ))
    local udp_low=$(( total_pages * 4 / 100 ))
    local udp_pressure=$(( total_pages * 6 / 100 ))
    local udp_max=$(( total_pages * 9 / 100 ))

    local min_free=$(( RAM_MB * 1024 / 128 ))
    (( min_free < 65536 )) && min_free=65536
    (( min_free > 1048576 )) && min_free=1048576

    local ct_max ct_buckets
    ct_max="$(compute_conntrack_max)"
    ct_buckets=$(( ct_max / 4 ))

    # Socket buffer ceiling: 32 MB is enough for long fat pipes without letting
    # a few thousand sockets eat the box.
    local sock_max=33554432
    local sock_default=1048576

    # BBR needs the module present; fq is its matching qdisc.
    local cc="cubic" qdisc="fq_codel"
    if modprobe tcp_bbr >/dev/null 2>&1 || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            cc="bbr"; qdisc="fq"
            write_file /etc/modules-load.d/99-pasarguard-bbr.conf <<'EOF'
# Loaded by the PasarGuard optimizer so BBR survives reboots.
tcp_bbr
EOF
        fi
    fi
    [[ "${cc}" == "bbr" ]] || warn "BBR unavailable on this kernel; keeping ${cc}/${qdisc}"

    # Make conntrack knobs visible before we probe for them.
    modprobe nf_conntrack >/dev/null 2>&1 || true

    local -a candidates=(
        "# Managed by PasarGuard optimizer v${OPTIMIZER_VERSION} (profile: ${PROFILE})"
        "# Host: ${CPU_CORES} cores / $(human_mb "${RAM_MB}") RAM. Regenerate with scripts/optimizer.sh."
        "# Remove this file and run 'sysctl --system' to revert."
        ""
        "## ---- file descriptors & inotify ----"
        "fs.file-max = 2097152"
        "fs.nr_open = 2097152"
        "fs.inotify.max_user_instances = 8192"
        "fs.inotify.max_user_watches = 524288"
        "fs.aio-max-nr = 1048576"
        ""
        "## ---- core networking ----"
        "net.core.somaxconn = 65535"
        "net.core.netdev_max_backlog = 65535"
        "net.core.rmem_max = ${sock_max}"
        "net.core.wmem_max = ${sock_max}"
        "net.core.rmem_default = ${sock_default}"
        "net.core.wmem_default = ${sock_default}"
        "net.core.optmem_max = 262144"
        "net.core.default_qdisc = ${qdisc}"
        "net.core.netdev_budget = 600"
        "net.core.netdev_budget_usecs = 8000"
        ""
        "## ---- TCP: buffers and memory pressure ----"
        "net.ipv4.tcp_rmem = 4096 262144 ${sock_max}"
        "net.ipv4.tcp_wmem = 4096 262144 ${sock_max}"
        "net.ipv4.tcp_mem = ${tcp_low} ${tcp_pressure} ${tcp_max}"
        "net.ipv4.udp_mem = ${udp_low} ${udp_pressure} ${udp_max}"
        "net.ipv4.udp_rmem_min = 16384"
        "net.ipv4.udp_wmem_min = 16384"
        "net.ipv4.tcp_moderate_rcvbuf = 1"
        ""
        "## ---- TCP: congestion control and throughput ----"
        "net.ipv4.tcp_congestion_control = ${cc}"
        "net.ipv4.tcp_slow_start_after_idle = 0"
        "net.ipv4.tcp_no_metrics_save = 1"
        "net.ipv4.tcp_mtu_probing = 1"
        "net.ipv4.tcp_window_scaling = 1"
        "net.ipv4.tcp_sack = 1"
        "net.ipv4.tcp_fack = 1"
        "net.ipv4.tcp_timestamps = 1"
        "net.ipv4.tcp_fastopen = 3"
        ""
        "## ---- TCP: accept queue and SYN handling ----"
        "net.ipv4.tcp_max_syn_backlog = 65535"
        "net.ipv4.tcp_syncookies = 1"
        "net.ipv4.tcp_syn_retries = 3"
        "net.ipv4.tcp_synack_retries = 2"
        "net.ipv4.tcp_abort_on_overflow = 0"
        ""
        "## ---- TCP: connection teardown at scale ----"
        "# Hundreds of thousands of subscription fetches churn sockets fast;"
        "# short FIN/TIME_WAIT windows keep the local port range from filling."
        "net.ipv4.tcp_fin_timeout = 15"
        "net.ipv4.tcp_tw_reuse = 1"
        "net.ipv4.tcp_max_tw_buckets = 1440000"
        "net.ipv4.tcp_max_orphans = 262144"
        "net.ipv4.tcp_orphan_retries = 2"
        "net.ipv4.tcp_retries2 = 8"
        "net.ipv4.ip_local_port_range = 10240 65535"
        ""
        "## ---- TCP: keepalive (drops dead client sockets quickly) ----"
        "net.ipv4.tcp_keepalive_time = 300"
        "net.ipv4.tcp_keepalive_intvl = 30"
        "net.ipv4.tcp_keepalive_probes = 5"
        ""
        "## ---- ARP / neighbour tables ----"
        "net.ipv4.neigh.default.gc_thresh1 = 4096"
        "net.ipv4.neigh.default.gc_thresh2 = 8192"
        "net.ipv4.neigh.default.gc_thresh3 = 16384"
        "net.ipv6.neigh.default.gc_thresh1 = 4096"
        "net.ipv6.neigh.default.gc_thresh2 = 8192"
        "net.ipv6.neigh.default.gc_thresh3 = 16384"
        ""
        "## ---- connection tracking ----"
        "# ${ct_max} entries ≈ $(( ct_max * 320 / 1024 / 1024 )) MB of kernel memory."
        "net.netfilter.nf_conntrack_max = ${ct_max}"
        "net.netfilter.nf_conntrack_tcp_timeout_established = 3600"
        "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
        "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15"
        "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30"
        "net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30"
        "net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20"
        "net.netfilter.nf_conntrack_udp_timeout = 30"
        "net.netfilter.nf_conntrack_udp_timeout_stream = 120"
        "net.netfilter.nf_conntrack_generic_timeout = 120"
        "net.netfilter.nf_conntrack_tcp_loose = 1"
        ""
        "## ---- virtual memory ----"
        "vm.swappiness = 10"
        "vm.vfs_cache_pressure = 50"
        "vm.dirty_ratio = 10"
        "vm.dirty_background_ratio = 3"
        "vm.dirty_expire_centisecs = 1000"
        "vm.dirty_writeback_centisecs = 500"
        "vm.min_free_kbytes = ${min_free}"
        "vm.max_map_count = 262144"
        "vm.zone_reclaim_mode = 0"
        "vm.overcommit_memory = 0"
        ""
        "## ---- process / scheduler ----"
        "kernel.pid_max = 4194304"
        "kernel.threads-max = 1000000"
        "kernel.sched_autogroup_enabled = 0"
        "kernel.panic = 10"
    )

    if [[ "${PROFILE}" == "node" || "${PROFILE}" == "all-in-one" ]]; then
        candidates+=(
            ""
            "## ---- forwarding (proxy node) ----"
            "net.ipv4.ip_forward = 1"
            "net.ipv6.conf.all.forwarding = 1"
        )
    fi

    # Drop keys this kernel does not expose, so `sysctl --system` stays clean.
    local rendered="" line key dropped=0
    for line in "${candidates[@]}"; do
        if [[ -z "${line}" || "${line}" == \#* ]]; then
            rendered+="${line}"$'\n'
            continue
        fi
        key="${line%%=*}"
        key="${key// /}"
        if sysctl_supported "${key}"; then
            rendered+="${line}"$'\n'
        else
            dropped=$(( dropped + 1 ))
            rendered+="# (unsupported on this kernel) ${line}"$'\n'
        fi
    done
    (( dropped == 0 )) || note "${dropped} sysctl key(s) are not available on this kernel and were commented out."

    printf '%s' "${rendered}" | write_file "${conf}" 0644

    # Conntrack hash buckets are a module parameter, not a sysctl.
    if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
        write_file /etc/modprobe.d/99-pasarguard-conntrack.conf 0644 <<EOF
# Managed by PasarGuard optimizer. Buckets ≈ nf_conntrack_max / 4 keeps the
# hash chains short; takes effect for the module load at boot.
options nf_conntrack hashsize=${ct_buckets}
EOF
        write_sysfs "${ct_buckets}" /sys/module/nf_conntrack/parameters/hashsize
    fi

    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s would run: sysctl --system\n' "${C_YELLOW}" "${C_RESET}"
    else
        local sysctl_errors
        sysctl_errors="$( { sysctl --system 2>&1 >/dev/null || true; } | sed -n 's/^sysctl: setting key "\([^"]*\)".*/\1/p' | sort -u | paste -sd', ' -)"
        if [[ -z "${sysctl_errors}" ]]; then
            ok "applied sysctl settings (cc=${cc}, qdisc=${qdisc}, conntrack_max=${ct_max})"
        else
            warn "the kernel refused these keys (read-only in this environment): ${sysctl_errors}"
            note "Refused sysctl keys are usually owned by the hypervisor on LXC/OpenVZ; ask the provider or ignore them."
        fi
    fi

    if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "openvz" || "${VIRT_TYPE}" == "lxc-libvirt" ]]; then
        warn "container virtualization (${VIRT_TYPE}): several kernel knobs are owned by the host and cannot be changed here"
    fi
}

# ---------------------------------------------------------------------------
# module: limits (file descriptors, processes)
# ---------------------------------------------------------------------------
module_limits() {
    heading "Resource limits (file descriptors, processes)"

    local nofile=1048576
    local nproc=1048576

    write_file /etc/security/limits.d/99-pasarguard.conf <<EOF
# Managed by PasarGuard optimizer v${OPTIMIZER_VERSION}.
# Applies to login sessions (PAM). systemd services take their limits from
# /etc/systemd/system.conf.d/99-pasarguard.conf instead.
*       soft    nofile  ${nofile}
*       hard    nofile  ${nofile}
*       soft    nproc   ${nproc}
*       hard    nproc   ${nproc}
root    soft    nofile  ${nofile}
root    hard    nofile  ${nofile}
root    soft    nproc   ${nproc}
root    hard    nproc   ${nproc}
*       soft    memlock unlimited
*       hard    memlock unlimited
EOF

    local systemd_limits
    systemd_limits="$(cat <<EOF
# Managed by PasarGuard optimizer v${OPTIMIZER_VERSION}.
[Manager]
DefaultLimitNOFILE=${nofile}:${nofile}
DefaultLimitNPROC=${nproc}:${nproc}
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=infinity
EOF
)"
    printf '%s\n' "${systemd_limits}" | write_file /etc/systemd/system.conf.d/99-pasarguard.conf
    printf '%s\n' "${systemd_limits}" | write_file /etc/systemd/user.conf.d/99-pasarguard.conf

    # Per-service drop-ins, so a restart is enough for the services that matter.
    local svc
    for svc in docker pasarguard postgresql nginx; do
        systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || continue
        systemctl cat "${svc}.service" >/dev/null 2>&1 || continue
        write_file "/etc/systemd/system/${svc}.service.d/99-pasarguard-limits.conf" <<EOF
# Managed by PasarGuard optimizer v${OPTIMIZER_VERSION}.
[Service]
LimitNOFILE=${nofile}
LimitNPROC=${nproc}
LimitMEMLOCK=infinity
TasksMax=infinity
EOF
        need_restart "${svc}"
    done

    # pam_limits must be active for the limits.d file to take effect on login.
    if [[ -f /etc/pam.d/common-session ]] && ! grep -q '^session.*pam_limits.so' /etc/pam.d/common-session; then
        warn "pam_limits.so missing from /etc/pam.d/common-session; interactive shells keep the old nofile limit"
    fi

    run_cmd "reloaded systemd manager configuration" systemctl daemon-reload
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s would run: systemctl daemon-reexec\n' "${C_YELLOW}" "${C_RESET}"
    else
        run_cmd "re-executed systemd (new DefaultLimit* active)" systemctl daemon-reexec
    fi
    note "Existing shells keep their old ulimit; re-login or reboot to pick up ${nofile}."
}

# ---------------------------------------------------------------------------
# module: transparent huge pages
# ---------------------------------------------------------------------------
module_thp() {
    heading "Transparent huge pages"

    if [[ ! -d /sys/kernel/mm/transparent_hugepage ]]; then
        skip "THP not exposed by this kernel"
        return 0
    fi

    # PostgreSQL and any process with a large, randomly-written shared buffer
    # pays for khugepaged compaction stalls. 'never' is the standard DB setting.
    write_file /etc/systemd/system/pasarguard-thp.service <<'EOF'
# Managed by PasarGuard optimizer.
[Unit]
Description=Disable transparent huge pages for PasarGuard workloads
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled || true'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'

[Install]
WantedBy=basic.target
EOF

    run_cmd "enabled pasarguard-thp.service" systemctl enable pasarguard-thp.service
    write_sysfs never /sys/kernel/mm/transparent_hugepage/enabled
    write_sysfs never /sys/kernel/mm/transparent_hugepage/defrag
    (( DRY_RUN )) || ok "THP set to never (now and at boot)"
}

# ---------------------------------------------------------------------------
# module: swap
# ---------------------------------------------------------------------------
module_swap() {
    heading "Swap"

    if (( ! CREATE_SWAP )); then
        skip "swap creation disabled (--no-swap)"
        return 0
    fi

    local swap_kb
    swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    if (( swap_kb > 0 )); then
        ok "swap already active ($(human_mb $(( swap_kb / 1024 ))))"
        return 0
    fi

    if [[ "${VIRT_TYPE}" == "lxc" || "${VIRT_TYPE}" == "openvz" ]]; then
        skip "container virtualization (${VIRT_TYPE}) — swap is managed by the host"
        return 0
    fi

    # A small swap file is insurance against an OOM kill of the panel or the
    # database during a usage-recording spike. vm.swappiness=10 keeps it idle.
    local size_gb=4
    (( RAM_MB >= 65536 )) && size_gb=8
    (( RAM_MB <= 8192 )) && size_gb=2

    local avail_mb
    avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
    if (( avail_mb < size_gb * 1024 + 5120 )); then
        warn "only ${avail_mb}MB free on / — skipping ${size_gb}GB swap file"
        return 0
    fi

    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s would create /swapfile (%sGB) and add it to /etc/fstab\n' \
            "${C_YELLOW}" "${C_RESET}" "${size_gb}"
        return 0
    fi

    step "creating ${size_gb}GB swap file"
    if ! fallocate -l "${size_gb}G" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=$(( size_gb * 1024 )) status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    if ! grep -q '^/swapfile' /etc/fstab; then
        backup_file /etc/fstab
        printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    fi
    ok "swap file active ($(human_mb $(( size_gb * 1024 ))), swappiness=10)"
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
}

# ---------------------------------------------------------------------------
# module: block I/O
# ---------------------------------------------------------------------------
module_io() {
    heading "Block I/O scheduler"

    write_file /etc/udev/rules.d/60-pasarguard-scheduler.rules <<'EOF'
# Managed by PasarGuard optimizer.
# NVMe: the device queues far better than the kernel can, so stay out of the way.
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/rq_affinity}="2"

# SSD / virtual disks: mq-deadline bounds write latency without BFQ's overhead.
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/nr_requests}="512"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="256"

# Spinning rust: seek ordering still pays off.
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="1024"
EOF

    run_cmd "reloaded udev rules" udevadm control --reload-rules
    run_cmd "re-applied block device rules" udevadm trigger --subsystem-match=block

    if (( ! DRY_RUN )); then
        local dev sched
        for dev in /sys/block/{nvme*n*,sd[a-z],vd[a-z]}; do
            [[ -r "${dev}/queue/scheduler" ]] || continue
            sched="$(sed -n 's/.*\[\(.*\)\].*/\1/p' "${dev}/queue/scheduler")"
            info "    $(basename "${dev}"): scheduler=${sched:-n/a}"
        done
    fi
}

# ---------------------------------------------------------------------------
# module: CPU governor
# ---------------------------------------------------------------------------
module_cpu() {
    heading "CPU frequency governor"

    if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        skip "no cpufreq control on this host (typical for KVM/cloud guests)"
        return 0
    fi

    local available
    available="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || true)"
    if [[ "${available}" != *performance* ]]; then
        skip "'performance' governor not available (have: ${available:-none})"
        return 0
    fi

    write_file /etc/systemd/system/pasarguard-cpu-governor.service <<'EOF'
# Managed by PasarGuard optimizer.
[Unit]
Description=Pin CPU governor to performance for PasarGuard
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" || true; done'

[Install]
WantedBy=multi-user.target
EOF
    run_cmd "enabled pasarguard-cpu-governor.service" systemctl enable pasarguard-cpu-governor.service

    if (( ! DRY_RUN )); then
        local g
        for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            write_sysfs performance "${g}"
        done
        ok "governor set to performance on ${CPU_CORES} core(s)"
    fi
}

# ---------------------------------------------------------------------------
# module: NIC
# ---------------------------------------------------------------------------
cpu_mask_hex() {
    # Hex bitmask covering all online CPUs, comma-grouped per 32 bits.
    local cores=$1 group mask="" i
    local groups=$(( (cores + 31) / 32 ))
    for (( i = 0; i < groups; i++ )); do
        local bits=$(( cores - i * 32 ))
        (( bits > 32 )) && bits=32
        if (( bits == 32 )); then
            group="ffffffff"
        else
            group="$(printf '%x' $(( (1 << bits) - 1 )))"
        fi
        if [[ -z "${mask}" ]]; then mask="${group}"; else mask="${group},${mask}"; fi
    done
    printf '%s' "${mask:-0}"
}

module_nic() {
    heading "Network interface (${PRIMARY_NIC:-not detected})"

    if [[ -z "${PRIMARY_NIC}" ]]; then
        skip "no default-route interface found"
        return 0
    fi
    if ! has_cmd ethtool; then
        warn "ethtool not installed — run: apt-get install -y ethtool, then re-run --only nic"
        return 0
    fi

    local rx_max tx_max rx_cur tx_cur
    rx_max="$(ethtool -g "${PRIMARY_NIC}" 2>/dev/null | awk '/^Pre-set maximums:/,/^Current/ {if ($1 == "RX:") {print $2; exit}}' || true)"
    tx_max="$(ethtool -g "${PRIMARY_NIC}" 2>/dev/null | awk '/^Pre-set maximums:/,/^Current/ {if ($1 == "TX:") {print $2; exit}}' || true)"
    rx_cur="$(ethtool -g "${PRIMARY_NIC}" 2>/dev/null | awk '/^Current hardware settings:/,0 {if ($1 == "RX:") {print $2; exit}}' || true)"
    tx_cur="$(ethtool -g "${PRIMARY_NIC}" 2>/dev/null | awk '/^Current hardware settings:/,0 {if ($1 == "TX:") {print $2; exit}}' || true)"

    local queues mask
    queues="$( { find "/sys/class/net/${PRIMARY_NIC}/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null || true; } | wc -l)"
    mask="$(cpu_mask_hex "${CPU_CORES}")"

    local tune_script="/usr/local/sbin/pasarguard-nettune.sh"
    write_file "${tune_script}" 0755 <<EOF
#!/bin/sh
# Managed by PasarGuard optimizer v${OPTIMIZER_VERSION}. Re-applied at boot by
# pasarguard-nettune.service; every command is best-effort.
IFACE="${PRIMARY_NIC}"
[ -d "/sys/class/net/\${IFACE}" ] || exit 0

# Bigger ring buffers absorb bursts instead of dropping frames.
ethtool -G "\${IFACE}" rx ${rx_max:-4096} tx ${tx_max:-4096} 2>/dev/null || true

# Hardware segmentation offloads: keep the CPU out of the per-packet path.
ethtool -K "\${IFACE}" gro on gso on tso on 2>/dev/null || true

# Spread softirq processing across cores when the NIC has a single RX queue.
if [ "\$(ls -1d /sys/class/net/\${IFACE}/queues/rx-* 2>/dev/null | wc -l)" -le 1 ]; then
    for q in /sys/class/net/\${IFACE}/queues/rx-*/rps_cpus; do
        [ -w "\$q" ] && echo ${mask} > "\$q" 2>/dev/null || true
    done
    for q in /sys/class/net/\${IFACE}/queues/rx-*/rps_flow_cnt; do
        [ -w "\$q" ] && echo 32768 > "\$q" 2>/dev/null || true
    done
    sysctl -qw net.core.rps_sock_flow_entries=262144 2>/dev/null || true
fi

# Transmit queue steering follows the sending CPU.
i=0
for q in /sys/class/net/\${IFACE}/queues/tx-*/xps_cpus; do
    [ -w "\$q" ] && printf '%x' \$(( 1 << (i % ${CPU_CORES}) )) > "\$q" 2>/dev/null || true
    i=\$((i + 1))
done

ip link set dev "\${IFACE}" txqueuelen 10000 2>/dev/null || true
EOF

    write_file /etc/systemd/system/pasarguard-nettune.service <<EOF
# Managed by PasarGuard optimizer.
[Unit]
Description=PasarGuard NIC tuning for ${PRIMARY_NIC}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${tune_script}

[Install]
WantedBy=multi-user.target
EOF

    run_cmd "enabled pasarguard-nettune.service" systemctl enable pasarguard-nettune.service
    run_cmd "applied NIC tuning to ${PRIMARY_NIC}" "${tune_script}"

    if (( ! DRY_RUN )); then
        info "    rings: rx ${rx_cur:-?}→${rx_max:-?}, tx ${tx_cur:-?}→${tx_max:-?}; rx queues: ${queues}"
    fi

    if ! systemctl is-active --quiet irqbalance 2>/dev/null && (( queues > 1 )); then
        note "Multi-queue NIC without irqbalance: apt-get install -y irqbalance && systemctl enable --now irqbalance"
    fi
}

# ---------------------------------------------------------------------------
# module: docker
# ---------------------------------------------------------------------------
module_docker() {
    heading "Docker daemon"

    if ! has_cmd docker; then
        skip "docker not installed"
        return 0
    fi

    local daemon_json="/etc/docker/daemon.json"
    local desired
    # Unbounded json-file logs are the single most common way a panel host runs
    # out of disk: 300k users generate a lot of access logging.
    desired="$(cat <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3",
    "compress": "true"
  },
  "live-restore": true,
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 1048576, "Soft": 1048576 },
    "nproc": { "Name": "nproc", "Hard": 1048576, "Soft": 1048576 }
  },
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 10
}
EOF
)"

    if [[ -f "${daemon_json}" ]] && has_cmd python3; then
        local merged
        if merged="$(DESIRED="${desired}" python3 - "${daemon_json}" <<'PY'
import json, os, sys

path = sys.argv[1]
desired = json.loads(os.environ["DESIRED"])
try:
    with open(path) as fh:
        current = json.load(fh)
    if not isinstance(current, dict):
        raise ValueError("daemon.json is not an object")
except FileNotFoundError:
    current = {}
except Exception as exc:  # malformed file: do not silently discard it
    print(f"PARSE_ERROR:{exc}", file=sys.stderr)
    raise SystemExit(2)

# Existing operator choices win; we only fill in what is unset, except for the
# log caps, which are the whole point of this module.
forced = {"log-driver", "log-opts", "default-ulimits"}
for key, value in desired.items():
    if key in forced or key not in current:
        current[key] = value

print(json.dumps(current, indent=2))
PY
        )"; then
            printf '%s\n' "${merged}" | write_file "${daemon_json}"
        else
            warn "${daemon_json} is not valid JSON — leaving it alone. Fix it, then re-run --only docker"
            return 0
        fi
    elif [[ -f "${daemon_json}" ]]; then
        warn "python3 unavailable, cannot merge existing ${daemon_json} safely — skipping"
        return 0
    else
        printf '%s\n' "${desired}" | write_file "${daemon_json}"
    fi

    need_restart docker
    note "Restarting docker applies the new log caps to newly created containers; existing containers keep their current log config until recreated."

    # Reclaim space from logs that were already written without a cap.
    if (( ! DRY_RUN )); then
        local logsize
        logsize="$( { du -shc /var/lib/docker/containers/*/*-json.log 2>/dev/null || true; } | tail -n1 | awk '{print $1}')"
        if [[ -n "${logsize}" && "${logsize}" != "0" ]]; then
            note "Existing container logs occupy ${logsize}; reclaim with: truncate -s 0 /var/lib/docker/containers/*/*-json.log"
        fi
    fi
}

# ---------------------------------------------------------------------------
# module: journald
# ---------------------------------------------------------------------------
module_journald() {
    heading "systemd-journald"

    write_file /etc/systemd/journald.conf.d/99-pasarguard.conf <<'EOF'
# Managed by PasarGuard optimizer.
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=512M
SystemMaxFileSize=64M
SystemMaxFiles=10
RuntimeMaxUse=128M
MaxRetentionSec=1week
# A busy panel can emit thousands of lines a second; rate limiting keeps
# journald from becoming the bottleneck, and the burst is generous enough
# that real incidents are still captured in full.
RateLimitIntervalSec=30s
RateLimitBurst=20000
ForwardToSyslog=no
EOF

    run_cmd "restarted systemd-journald" systemctl restart systemd-journald
}

# ---------------------------------------------------------------------------
# module: database
# ---------------------------------------------------------------------------
recommended_workers() {
    if [[ -n "${WORKERS_OVERRIDE}" ]]; then
        printf '%s' "${WORKERS_OVERRIDE}"
        return 0
    fi
    # Leave headroom for PostgreSQL, Xray/node-bridge and the OS.
    local w=$(( CPU_CORES * 3 / 4 ))
    (( w < 1 )) && w=1
    (( w > 16 )) && w=16
    printf '%s' "${w}"
}

pg_max_connections() {
    local workers pool
    workers="$(recommended_workers)"
    pool=$(( workers * 20 ))          # POOL_SIZE 10 + MAX_OVERFLOW 10 per worker
    local total=$(( pool + 80 ))      # scheduler, CLI, backups, monitoring
    (( total < 100 )) && total=100
    (( total > 500 )) && total=500
    printf '%s' "${total}"
}

render_postgres_conf() {
    local shared_mb=$(( RAM_MB / 4 ))
    (( shared_mb > 12288 )) && shared_mb=12288
    (( shared_mb < 256 )) && shared_mb=256

    local cache_mb=$(( RAM_MB * 55 / 100 ))
    local maint_mb=$(( RAM_MB / 16 ))
    (( maint_mb > 2048 )) && maint_mb=2048
    (( maint_mb < 64 )) && maint_mb=64

    local max_conn work_mb
    max_conn="$(pg_max_connections)"
    work_mb=$(( RAM_MB * 15 / 100 / max_conn ))
    (( work_mb < 4 )) && work_mb=4
    (( work_mb > 64 )) && work_mb=64

    local wal_buffers_mb=$(( shared_mb / 32 ))
    (( wal_buffers_mb > 64 )) && wal_buffers_mb=64
    (( wal_buffers_mb < 8 )) && wal_buffers_mb=8

    local par_gather=$(( CPU_CORES / 2 ))
    (( par_gather < 1 )) && par_gather=1
    (( par_gather > 8 )) && par_gather=8

    local av_workers=$(( CPU_CORES / 2 ))
    (( av_workers < 3 )) && av_workers=3
    (( av_workers > 8 )) && av_workers=8

    local rpc eio sync_commit
    if (( IS_SSD )); then rpc="1.1"; eio=200; else rpc="4.0"; eio=2; fi
    if [[ "${DB_DURABILITY}" == "strict" ]]; then sync_commit="on"; else sync_commit="off"; fi

    cat <<EOF
# Managed by PasarGuard optimizer v${OPTIMIZER_VERSION}
# Host: ${CPU_CORES} cores / $(human_mb "${RAM_MB}") RAM / $( ((IS_SSD)) && echo SSD-NVMe || echo HDD )
# Workload: PasarGuard panel, high user count, write-heavy usage recording.
# Delete this file and restart PostgreSQL to revert to stock settings.

#--- memory -----------------------------------------------------------------
shared_buffers = ${shared_mb}MB
effective_cache_size = ${cache_mb}MB
maintenance_work_mem = ${maint_mb}MB
work_mem = ${work_mb}MB
# 'try' falls back to 4K pages when no huge pages are reserved, so it is safe
# to leave on. To actually reserve them: vm.nr_hugepages = shared_buffers/2MB.
huge_pages = try

#--- connections ------------------------------------------------------------
# Budget: ${max_conn} = (UVICORN_WORKERS x (POOL_SIZE + MAX_OVERFLOW)) + headroom.
# Raising UVICORN_WORKERS or the pool sizes means raising this too.
max_connections = ${max_conn}
superuser_reserved_connections = 5
idle_in_transaction_session_timeout = 60s
tcp_keepalives_idle = 60
tcp_keepalives_interval = 10
tcp_keepalives_count = 6

#--- write-ahead log --------------------------------------------------------
wal_buffers = ${wal_buffers_mb}MB
wal_compression = on
min_wal_size = 2GB
max_wal_size = 8GB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
# synchronous_commit=${sync_commit}: '${DB_DURABILITY}' durability mode.
# off  -> a hard crash can lose up to ~1s of committed usage counters.
#         The database is never corrupted; only the newest commits are lost.
# on   -> every commit waits for fsync (use --db-durability strict).
synchronous_commit = ${sync_commit}

#--- planner ----------------------------------------------------------------
random_page_cost = ${rpc}
effective_io_concurrency = ${eio}
default_statistics_target = 100
# JIT costs more than it saves on the panel's short OLTP queries.
jit = off

#--- parallelism ------------------------------------------------------------
max_worker_processes = ${CPU_CORES}
max_parallel_workers = ${CPU_CORES}
max_parallel_workers_per_gather = ${par_gather}
max_parallel_maintenance_workers = ${par_gather}

#--- autovacuum -------------------------------------------------------------
# Usage counters are updated constantly, so the default 20% scale factor lets
# dead tuples pile up for far too long on the biggest tables.
autovacuum = on
autovacuum_max_workers = ${av_workers}
autovacuum_naptime = 15s
autovacuum_vacuum_scale_factor = 0.02
autovacuum_analyze_scale_factor = 0.01
autovacuum_vacuum_threshold = 1000
autovacuum_analyze_threshold = 1000
autovacuum_vacuum_cost_delay = 2ms
autovacuum_vacuum_cost_limit = 3000

#--- observability ----------------------------------------------------------
log_min_duration_statement = 1000
log_checkpoints = on
log_lock_waits = on
log_autovacuum_min_duration = 5000
log_temp_files = 10MB
track_io_timing = on
EOF

    if [[ -n "${PG_VERSION}" ]] && compgen -G "/usr/lib/postgresql/${PG_VERSION}/lib/timescaledb*.so" >/dev/null 2>&1; then
        cat <<EOF

#--- timescaledb ------------------------------------------------------------
timescaledb.max_background_workers = ${av_workers}
EOF
    fi
}

render_mysql_conf() {
    local pool_mb=$(( RAM_MB / 2 ))
    (( pool_mb > 24576 )) && pool_mb=24576
    (( pool_mb < 128 )) && pool_mb=128

    local instances=$(( pool_mb / 1024 ))
    (( instances < 1 )) && instances=1
    (( instances > 16 )) && instances=16

    local max_conn flush io_cap io_cap_max
    max_conn="$(pg_max_connections)"
    if [[ "${DB_DURABILITY}" == "strict" ]]; then flush=1; else flush=2; fi
    if (( IS_SSD )); then io_cap=4000; io_cap_max=8000; else io_cap=200; io_cap_max=400; fi

    cat <<EOF
# Managed by PasarGuard optimizer v${OPTIMIZER_VERSION}
# Host: ${CPU_CORES} cores / $(human_mb "${RAM_MB}") RAM.
[mysqld]
#--- innodb -----------------------------------------------------------------
innodb_buffer_pool_size = ${pool_mb}M
innodb_buffer_pool_instances = ${instances}
innodb_log_file_size = 2G
innodb_log_buffer_size = 64M
innodb_flush_method = O_DIRECT
# innodb_flush_log_at_trx_commit=${flush}: '${DB_DURABILITY}' durability mode.
# 2 flushes once per second — a crash can lose ~1s of usage counters.
innodb_flush_log_at_trx_commit = ${flush}
innodb_io_capacity = ${io_cap}
innodb_io_capacity_max = ${io_cap_max}
innodb_read_io_threads = ${CPU_CORES}
innodb_write_io_threads = ${CPU_CORES}
innodb_thread_concurrency = 0
innodb_purge_threads = 4
innodb_stats_persistent = ON

#--- connections ------------------------------------------------------------
max_connections = ${max_conn}
thread_cache_size = 128
back_log = 4096
wait_timeout = 600
interactive_timeout = 600
max_allowed_packet = 64M
skip-name-resolve

#--- tables and temp --------------------------------------------------------
table_open_cache = 16000
table_definition_cache = 8000
open_files_limit = 1048576
tmp_table_size = 128M
max_heap_table_size = 128M

#--- observability ----------------------------------------------------------
slow_query_log = 1
long_query_time = 1
EOF
}

module_database() {
    heading "Database (${DB_FLAVOR})"

    case "${DB_FLAVOR}" in
        sqlite)
            warn "SQLite cannot serve a deployment this size — a single writer serializes every usage update."
            note "Migrate to PostgreSQL and set SQLALCHEMY_DATABASE_URL=postgresql+asyncpg://... in ${ENV_FILE:-the panel .env}."
            return 0
            ;;
        unknown)
            skip "no database detected (no SQLALCHEMY_DATABASE_URL and no local server)"
            return 0
            ;;
    esac

    mkdir -p "${REPORT_DIR}"

    if [[ "${DB_FLAVOR}" == "postgresql" ]]; then
        if [[ -n "${PG_CONFDIR}" ]]; then
            local main_conf="${PG_CONFDIR}/postgresql.conf"
            local target="${PG_CONFDIR}/conf.d/99-pasarguard-tuning.conf"

            if [[ -f "${main_conf}" ]] && ! grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "${main_conf}"; then
                if (( DRY_RUN )); then
                    printf '  %s[dry-run]%s would append include_dir to %s\n' "${C_YELLOW}" "${C_RESET}" "${main_conf}"
                else
                    backup_file "${main_conf}"
                    printf "\n# Added by PasarGuard optimizer\ninclude_dir = 'conf.d'\n" >>"${main_conf}"
                    ok "enabled include_dir = 'conf.d' in ${main_conf}"
                fi
            fi

            render_postgres_conf | write_file "${target}" 0644
            (( DRY_RUN )) || chown postgres:postgres "${target}" 2>/dev/null || true

            # Parse the whole config the way the server will, so a bad value is
            # caught here instead of at the next restart.
            if (( ! DRY_RUN )) && [[ -x "/usr/lib/postgresql/${PG_VERSION}/bin/postgres" ]]; then
                local pg_check
                if pg_check="$(su postgres -c \
                    "/usr/lib/postgresql/${PG_VERSION}/bin/postgres --config-file='${main_conf}' -C shared_buffers" 2>&1)"; then
                    ok "PostgreSQL accepts the config (shared_buffers = ${pg_check} blocks)"
                else
                    warn "PostgreSQL rejected the generated config — reverting ${target}"
                    printf '%s\n' "${pg_check}" | sed 's/^/      /'
                    rm -f "${target}"
                    return 0
                fi
            fi

            need_restart postgresql
            note "PostgreSQL ${PG_VERSION}: shared_buffers and max_connections need a full restart, not a reload."
        else
            local target="${REPORT_DIR}/postgresql-tuning.conf"
            render_postgres_conf | write_file "${target}" 0644
            if (( PG_IN_DOCKER )); then
                note "PostgreSQL runs in Docker. Mount the generated file and include it, e.g.:"
                note "  volumes: [\"${target}:/etc/postgresql/conf.d/99-pasarguard.conf:ro\"]"
                note "  command: postgres -c config_file=/etc/postgresql/postgresql.conf   # with include_dir = '/etc/postgresql/conf.d'"
                note "Or pass each setting as '-c key=value' on the postgres command line."
            else
                note "PostgreSQL is remote or not installed locally; apply ${target} on the database host."
            fi
        fi
    fi

    if [[ "${DB_FLAVOR}" == "mysql" ]]; then
        if [[ -n "${MYSQL_CONFDIR}" ]]; then
            render_mysql_conf | write_file "${MYSQL_CONFDIR}/99-pasarguard-tuning.cnf" 0644
            need_restart mysql
            note "MySQL/MariaDB: changing innodb_log_file_size requires a clean shutdown before restart."
        else
            local target="${REPORT_DIR}/mysql-tuning.cnf"
            render_mysql_conf | write_file "${target}" 0644
            note "MySQL is remote or containerized; apply ${target} on the database host."
        fi
    fi
}

# ---------------------------------------------------------------------------
# module: nginx
# ---------------------------------------------------------------------------
module_nginx() {
    heading "Nginx reverse proxy"

    if ! has_cmd nginx || [[ ! -f /etc/nginx/nginx.conf ]]; then
        skip "nginx not installed"
        return 0
    fi

    local main_conf="/etc/nginx/nginx.conf"
    local worker_conn=65535
    local rlimit=1048576

    write_file /etc/nginx/conf.d/99-pasarguard-tuning.conf <<EOF
# Managed by PasarGuard optimizer v${OPTIMIZER_VERSION}.
# http{} level tuning for a subscription endpoint under heavy fetch load.

# Reuse upstream connections to the panel instead of a new TCP+TLS handshake
# per subscription request. Pair with a 'keepalive' directive in your upstream.
proxy_http_version 1.1;
proxy_set_header Connection "";

keepalive_timeout 65s;
keepalive_requests 10000;
reset_timedout_connection on;

client_body_buffer_size 128k;
client_header_buffer_size 4k;
large_client_header_buffers 4 16k;
client_max_body_size 32m;
client_body_timeout 15s;
client_header_timeout 15s;
send_timeout 30s;

sendfile on;
tcp_nopush on;
tcp_nodelay on;

open_file_cache max=20000 inactive=60s;
open_file_cache_valid 60s;
open_file_cache_min_uses 2;
open_file_cache_errors on;

server_names_hash_bucket_size 128;
types_hash_max_size 4096;

gzip on;
gzip_vary on;
gzip_comp_level 5;
gzip_min_length 512;
gzip_proxied any;
gzip_types text/plain text/css application/json application/javascript application/xml text/xml application/x-yaml;
EOF

    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s would set worker_rlimit_nofile/worker_connections in %s\n' \
            "${C_YELLOW}" "${C_RESET}" "${main_conf}"
    else
        backup_file "${main_conf}"
        local before
        before="$(md5sum "${main_conf}" | awk '{print $1}')"

        if grep -qE '^[[:space:]]*worker_rlimit_nofile' "${main_conf}"; then
            sed -i -E "s|^[[:space:]]*worker_rlimit_nofile.*|worker_rlimit_nofile ${rlimit};|" "${main_conf}"
        else
            sed -i "0,/^worker_processes/s|^worker_processes.*|&\nworker_rlimit_nofile ${rlimit};|" "${main_conf}"
        fi

        if grep -qE '^[[:space:]]*worker_connections' "${main_conf}"; then
            sed -i -E "s|^([[:space:]]*)worker_connections.*|\1worker_connections ${worker_conn};|" "${main_conf}"
        fi
        if ! grep -qE '^[[:space:]]*multi_accept' "${main_conf}"; then
            sed -i -E "s|^([[:space:]]*)worker_connections(.*)|\1worker_connections\2\n\1multi_accept on;|" "${main_conf}"
        fi

        if nginx -t >/dev/null 2>&1; then
            local after
            after="$(md5sum "${main_conf}" | awk '{print $1}')"
            if [[ "${before}" == "${after}" ]]; then
                skip "${main_conf} already tuned"
            else
                ok "worker_rlimit_nofile=${rlimit}, worker_connections=${worker_conn}"
                CHANGED_COUNT=$((CHANGED_COUNT + 1))
            fi
            need_restart nginx
        else
            warn "nginx -t failed after editing ${main_conf} — restoring the original"
            cp -a "${BACKUP_DIR}/files${main_conf}" "${main_conf}"
            nginx -t 2>&1 | sed 's/^/      /' || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# module: services
# ---------------------------------------------------------------------------
module_services() {
    heading "System services"

    # Multi-queue NICs need IRQ spreading, or one core saturates on softirq.
    if [[ -n "${PRIMARY_NIC}" ]]; then
        local queues
        queues="$( { find "/sys/class/net/${PRIMARY_NIC}/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null || true; } | wc -l)"
        if (( queues > 1 )); then
            if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
                run_cmd "enabled irqbalance" systemctl enable --now irqbalance
            else
                note "Install irqbalance for the ${queues}-queue NIC: apt-get install -y irqbalance"
            fi
        else
            skip "single-queue NIC — RPS already handles softirq spreading"
        fi
    fi

    # Clock skew breaks JWT validation and usage accounting alike.
    if systemctl is-active --quiet chrony 2>/dev/null; then
        ok "chrony active (time sync)"
    elif systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
        run_cmd "enabled systemd-timesyncd" systemctl enable --now systemd-timesyncd
    else
        note "No time sync daemon found. Install one: apt-get install -y chrony"
    fi

    # Crash dumps from a busy panel fill the disk and help nobody.
    local svc
    for svc in apport whoopsie; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 \
           && systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            run_cmd "disabled ${svc}" systemctl disable --now "${svc}"
        fi
    done

    if systemctl is-enabled --quiet snapd 2>/dev/null; then
        note "snapd is enabled and periodically refreshes in the background; consider removing it on a dedicated panel host."
    fi
}

# ---------------------------------------------------------------------------
# module: panel .env
# ---------------------------------------------------------------------------
env_recommendations() {
    local workers
    workers="$(recommended_workers)"
    local nats_line
    if (( NATS_REACHABLE )); then
        nats_line="NATS_ENABLED = True"
    else
        # UVICORN_WORKERS > 1 without NATS is rejected at startup, so never
        # hand the operator a config that refuses to boot.
        workers=1
        nats_line="# NATS_ENABLED = True   # required before raising UVICORN_WORKERS above 1"
    fi

    cat <<EOF
## PasarGuard tuning generated by optimizer v${OPTIMIZER_VERSION}
## Host: ${CPU_CORES} cores / $(human_mb "${RAM_MB}") RAM. Profile: ${PROFILE}.

## --- HTTP workers --------------------------------------------------------
## ${workers} workers leaves cores for PostgreSQL, node-bridge and the OS.
## Workers > 1 REQUIRES NATS: main.py calls require_nats_if_multiworker().
UVICORN_WORKERS = ${workers}
${nats_line}
UVICORN_LOOP = "uvloop"

## --- database pool -------------------------------------------------------
## The ceiling is (POOL_SIZE + MAX_OVERFLOW) x worker count
## = ($((10 + 10))) x ${workers} = $(( 20 * workers )) connections.
## Keep it below the server's max_connections.
SQLALCHEMY_POOL_SIZE = 10
SQLALCHEMY_MAX_OVERFLOW = 10
SQLALCHEMY_POOL_RECYCLE = 900
SQLALCHEMY_POOL_TIMEOUT = 10

## --- logging -------------------------------------------------------------
## INFO-level access logging is a measurable cost at this request volume.
LOG_LEVEL = "WARNING"
SAVE_LOGS_TO_FILE = False
DOCS = False
DEBUG = False
ECHO_SQL_QUERIES = False

## --- background jobs -----------------------------------------------------
## Each job sweeps every user. At 300k users the stock intervals overlap,
## so runs queue on top of each other and the database never gets idle time.
JOB_RECORD_USER_USAGES_INTERVAL = 20
JOB_RECORD_NODE_USAGES_INTERVAL = 60
JOB_REVIEW_USERS_INTERVAL = 60
JOB_REVIEW_ADMIN_LIMITS_INTERVAL = 30
JOB_CORE_HEALTH_CHECK_INTERVAL = 20
JOB_GATHER_NODES_STATS_INTERVAL = 60
JOB_SEND_NOTIFICATIONS_INTERVAL = 30
JOB_RESET_USER_DATA_USAGE_INTERVAL = 900
JOB_RESET_NODE_USAGE_INTERVAL = 120
JOB_CHECK_NODE_LIMITS_INTERVAL = 120
JOB_CLEANUP_SUBSCRIPTION_UPDATES_INTERVAL = 900
JOB_REMOVE_OLD_INBOUNDS_INTERVAL = 1800
JOB_REMOVE_EXPIRED_USERS_INTERVAL = 7200

## --- node synchronisation ------------------------------------------------
## Larger batches mean far fewer NATS round trips per full user sync.
NATS_NODE_UPDATE_USERS_BATCH_SIZE = 500

## --- optional ------------------------------------------------------------
## Per-node time-series stats are PostgreSQL/TimescaleDB only and add steady
## write load. Leave off unless you actually read those charts.
ENABLE_RECORDING_NODES_STATS = False
## Behind nginx/Caddy, uncomment so client IPs and scheme are trusted:
# UVICORN_PROXY_HEADERS = True
# UVICORN_FORWARDED_ALLOW_IPS = "127.0.0.1"
EOF
}

env_set() {
    # env_set <file> <KEY> <value> — update in place or append, preserving style
    local file=$1 key=$2 value=$3
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "${file}"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${file}"
    else
        printf '%s = %s\n' "${key}" "${value}" >>"${file}"
    fi
}

module_env() {
    heading "PasarGuard configuration (.env)"

    mkdir -p "${REPORT_DIR}"
    local rec="${REPORT_DIR}/env-recommendations.env"
    env_recommendations | write_file "${rec}" 0640

    if [[ -z "${ENV_FILE}" || ! -f "${ENV_FILE}" ]]; then
        warn "panel .env not found — recommendations written to ${rec}"
        note "Point the optimizer at it with --env-file /path/to/.env"
        return 0
    fi

    if (( NATS_REACHABLE )); then
        ok "NATS reachable — multi-worker mode is safe to enable"
    else
        warn "NATS not reachable: keeping UVICORN_WORKERS=1 (workers > 1 fails startup without NATS)"
        note "Add a NATS service, then re-run: $0 --only env --apply-env"
    fi

    if (( ! APPLY_ENV )); then
        info "  Review and apply: ${rec}"
        note "Re-run with --apply-env to write these values into ${ENV_FILE} (backed up first)."
        return 0
    fi

    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s would patch %s with the values in %s\n' \
            "${C_YELLOW}" "${C_RESET}" "${ENV_FILE}" "${rec}"
        return 0
    fi

    backup_file "${ENV_FILE}"
    local line key value applied=0
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ = ]] || continue
        key="$(printf '%s' "${line%%=*}" | tr -d '[:space:]')"
        value="$(printf '%s' "${line#*=}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -n "${key}" ]] || continue
        env_set "${ENV_FILE}" "${key}" "${value}"
        applied=$(( applied + 1 ))
    done < <(env_recommendations)

    ok "applied ${applied} settings to ${ENV_FILE}"
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    need_restart pasarguard
}

# ---------------------------------------------------------------------------
# check mode — read-only diagnostics
# ---------------------------------------------------------------------------
kv() { printf '  %-34s %s\n' "$1" "$2"; }

kv_cmp() {
    # kv_cmp <label> <current> <wanted> [numeric]
    local label=$1 current=$2 wanted=$3 numeric=${4:-0} mark
    if [[ "${numeric}" == "1" && "${current}" =~ ^[0-9]+$ && "${wanted}" =~ ^[0-9]+$ ]]; then
        (( current >= wanted )) && mark="${C_GREEN}ok${C_RESET}" || mark="${C_YELLOW}low${C_RESET}"
    else
        [[ "${current}" == "${wanted}" ]] && mark="${C_GREEN}ok${C_RESET}" || mark="${C_YELLOW}differs${C_RESET}"
    fi
    printf '  %-34s %-22s (want %s) [%s]\n' "${label}" "${current}" "${wanted}" "${mark}"
}

sysctl_or_na() { sysctl -n "$1" 2>/dev/null | tr '\t' ' ' || printf 'n/a'; }

run_check() {
    heading "Host"
    kv "Kernel" "$(uname -r)"
    kv "Virtualization" "${VIRT_TYPE}"
    kv "CPU cores" "${CPU_CORES}"
    kv "RAM" "$(human_mb "${RAM_MB}")"
    kv "Root storage" "$( ((IS_SSD)) && echo 'SSD / NVMe' || echo 'rotational' )"
    kv "Primary NIC" "${PRIMARY_NIC:-not detected}"
    kv "Uptime / load" "$(uptime | sed 's/^ *//')"

    heading "PasarGuard"
    kv "Panel directory" "${PANEL_DIR:-not found}"
    kv "Config file" "${ENV_FILE:-not found}"
    kv "Database" "${DB_FLAVOR}"
    kv "UVICORN_WORKERS" "$(env_get UVICORN_WORKERS || echo '1 (default)')"
    kv "NATS_ENABLED" "$(env_get NATS_ENABLED || echo 'False (default)')"
    kv "NATS reachable" "$( ((NATS_REACHABLE)) && echo yes || echo no )"
    kv "LOG_LEVEL" "$(env_get LOG_LEVEL || echo 'INFO (default)')"
    kv "Pool size / overflow" "$(env_get SQLALCHEMY_POOL_SIZE || echo 5) / $(env_get SQLALCHEMY_MAX_OVERFLOW || echo 5)"
    if has_cmd docker; then
        local running
        running="$(docker ps --format '{{.Names}} ({{.Status}})' 2>/dev/null | paste -sd', ' - || true)"
        kv "Docker containers" "${running:-none}"
    fi

    heading "Kernel limits"
    kv_cmp "fs.file-max" "$(sysctl_or_na fs.file-max)" 2097152 1
    kv_cmp "fs.nr_open" "$(sysctl_or_na fs.nr_open)" 2097152 1
    kv_cmp "net.core.somaxconn" "$(sysctl_or_na net.core.somaxconn)" 65535 1
    kv_cmp "tcp_max_syn_backlog" "$(sysctl_or_na net.ipv4.tcp_max_syn_backlog)" 65535 1
    kv_cmp "netdev_max_backlog" "$(sysctl_or_na net.core.netdev_max_backlog)" 65535 1
    kv_cmp "tcp_congestion_control" "$(sysctl_or_na net.ipv4.tcp_congestion_control)" bbr
    kv_cmp "default_qdisc" "$(sysctl_or_na net.core.default_qdisc)" fq
    kv_cmp "tcp_tw_reuse" "$(sysctl_or_na net.ipv4.tcp_tw_reuse)" 1
    kv_cmp "vm.swappiness" "$(sysctl_or_na vm.swappiness)" 10
    kv "ip_local_port_range" "$(sysctl_or_na net.ipv4.ip_local_port_range)"
    kv "Current shell nofile" "$(ulimit -n)"

    heading "Live resource usage"
    local fd_alloc fd_max
    read -r fd_alloc _ fd_max < /proc/sys/fs/file-nr
    kv "Open file descriptors" "${fd_alloc} / ${fd_max} ($(awk -v a="${fd_alloc}" -v m="${fd_max}" 'BEGIN{printf "%.1f%%", (m>0? a*100/m : 0)}'))"

    if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
        local ct_count ct_max_now
        ct_count="$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
        ct_max_now="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
        local pct
        pct="$(awk -v c="${ct_count}" -v m="${ct_max_now}" 'BEGIN{printf "%.1f", (m>0? c*100/m : 0)}')"
        kv "Conntrack entries" "${ct_count} / ${ct_max_now} (${pct}%)"
        awk -v p="${pct}" 'BEGIN{exit !(p > 70)}' && warn "conntrack table above 70% — raise net.netfilter.nf_conntrack_max"
    else
        kv "Conntrack" "module not loaded"
    fi

    if has_cmd ss; then
        kv "Sockets (estab/tw/syn-recv)" "$(ss -tan 2>/dev/null | awk 'NR>1{c[$1]++} END{printf "%d / %d / %d", c["ESTAB"], c["TIME-WAIT"], c["SYN-RECV"]}')"
        kv "Listening sockets" "$(ss -tlnH 2>/dev/null | wc -l)"
    fi

    kv "Memory used" "$(free -m | awk '/^Mem:/ {printf "%s / %s MB (%.0f%%)", $3, $2, $3*100/$2}')"
    kv "Swap used" "$(free -m | awk '/^Swap:/ {if ($2 == 0) printf "no swap configured"; else printf "%s / %s MB", $3, $2}')"
    kv "THP" "$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"

    local root_dev sched
    root_dev="$( { lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null || true)" 2>/dev/null || true; } | head -n1)"
    if [[ -n "${root_dev}" && -r "/sys/block/${root_dev}/queue/scheduler" ]]; then
        sched="$(sed -n 's/.*\[\(.*\)\].*/\1/p' "/sys/block/${root_dev}/queue/scheduler")"
        kv "I/O scheduler (${root_dev})" "${sched}"
    fi
    kv "Disk / usage" "$(df -h / | awk 'NR==2 {printf "%s used of %s (%s)", $3, $2, $5}')"

    if has_cmd docker; then
        local logsize
        logsize="$( { du -shc /var/lib/docker/containers/*/*-json.log 2>/dev/null || true; } | tail -n1 | awk '{print $1}')"
        [[ -n "${logsize}" && "${logsize}" != "0" ]] && kv "Docker json logs" "${logsize}"
    fi

    heading "Database"
    if [[ "${DB_FLAVOR}" == "postgresql" && -n "${PG_CONFDIR}" ]] && has_cmd psql; then
        local conns maxc
        conns="$(su postgres -c "psql -tAc 'SELECT count(*) FROM pg_stat_activity'" 2>/dev/null || true)"
        maxc="$(su postgres -c "psql -tAc 'SHOW max_connections'" 2>/dev/null || true)"
        kv "Active connections" "${conns:-?} / ${maxc:-?}"
        kv "shared_buffers" "$(su postgres -c "psql -tAc 'SHOW shared_buffers'" 2>/dev/null || echo '?')"
        kv "synchronous_commit" "$(su postgres -c "psql -tAc 'SHOW synchronous_commit'" 2>/dev/null || echo '?')"
        kv "Database size" "$(su postgres -c "psql -tAc \"SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database\"" 2>/dev/null || echo '?')"
    else
        kv "Local inspection" "not available (${DB_FLAVOR}${PG_IN_DOCKER:+, containerized})"
    fi

    heading "Applied optimizer state"
    local f
    for f in /etc/sysctl.d/99-pasarguard-optimizer.conf \
             /etc/security/limits.d/99-pasarguard.conf \
             /etc/systemd/system.conf.d/99-pasarguard.conf \
             /etc/docker/daemon.json \
             /etc/systemd/journald.conf.d/99-pasarguard.conf; do
        local label="${f#/etc/}"
        [[ -f "${f}" ]] && kv "${label}" "present" || kv "${label}" "absent"
    done
    if [[ -d "${BACKUP_ROOT}" ]]; then
        kv "Rollback points" "$( { find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true; } | wc -l)"
    fi

    if (( ${#WARNINGS[@]} )); then
        heading "Attention"
        local w
        for w in "${WARNINGS[@]}"; do printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "${w}"; done
    fi
    printf '\n'
}

# ---------------------------------------------------------------------------
# rollback
# ---------------------------------------------------------------------------
list_backups() {
    heading "Rollback points"
    if [[ ! -d "${BACKUP_ROOT}" ]]; then
        info "  none yet (${BACKUP_ROOT} does not exist)"
        return 0
    fi
    local dir count
    local found=0
    while IFS= read -r dir; do
        [[ -f "${dir}/manifest.tsv" ]] || continue
        count="$( { awk 'NR > 1' "${dir}/manifest.tsv" || true; } | wc -l)"
        printf '  %-20s %s file(s)\n' "$(basename "${dir}")" "${count}"
        found=1
    done < <(find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d | sort)
    (( found )) || info "  none yet"
}

do_rollback() {
    local target="${ROLLBACK_TARGET}"
    if [[ "${target}" == "latest" ]]; then
        target="$( { find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true; } | sort | tail -n1)"
        [[ -n "${target}" ]] || die "no rollback points found in ${BACKUP_ROOT}"
    else
        target="${BACKUP_ROOT}/${target}"
    fi

    local manifest="${target}/manifest.tsv"
    [[ -f "${manifest}" ]] || die "no manifest at ${manifest}"

    heading "Rolling back $(basename "${target}")"
    awk 'NR > 1 {printf "  %s\n", $1}' "${manifest}"

    confirm "Restore these files to their pre-run state?" || die "aborted"

    local path backup existed restored=0 removed=0
    while IFS=$'\t' read -r path backup existed; do
        [[ "${path}" == \#* || -z "${path}" ]] && continue
        if [[ "${existed}" == "1" ]]; then
            if [[ -e "${target}/${backup}" ]]; then
                mkdir -p "$(dirname "${path}")"
                cp -a "${target}/${backup}" "${path}"
                ok "restored ${path}"
                restored=$(( restored + 1 ))
            else
                warn "backup missing for ${path}"
            fi
        else
            if [[ -e "${path}" ]]; then
                rm -f "${path}"
                ok "removed ${path} (did not exist before)"
                removed=$(( removed + 1 ))
            fi
        fi
    done < "${manifest}"

    run_cmd "reloaded sysctl" sysctl --system
    run_cmd "reloaded systemd" systemctl daemon-reload
    has_cmd udevadm && run_cmd "reloaded udev rules" udevadm control --reload-rules

    heading "Rollback complete"
    info "  ${restored} file(s) restored, ${removed} removed."
    info "  Restart affected services (docker, postgresql, nginx, pasarguard) to fully revert."
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
restart_services() {
    (( ${#NEEDS_RESTART[@]} )) || return 0
    local svc
    for svc in "${NEEDS_RESTART[@]}"; do
        systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || continue
        systemctl is-enabled --quiet "${svc}" 2>/dev/null || systemctl is-active --quiet "${svc}" 2>/dev/null || continue
        run_cmd "restarted ${svc}" systemctl restart "${svc}"
    done
}

print_summary() {
    heading "Summary"
    if (( DRY_RUN )); then
        info "  Dry run — nothing was written."
    else
        info "  ${CHANGED_COUNT} file(s) written, ${SKIPPED_COUNT} already current."
        [[ -f "${MANIFEST}" ]] && info "  Backups: ${BACKUP_DIR}"
        [[ -f "${MANIFEST}" ]] && info "  Rollback: $0 --rollback ${RUN_ID}"
    fi

    if (( ${#NOTES[@]} )); then
        heading "Next steps"
        local n
        for n in "${NOTES[@]}"; do printf '  %s•%s %s\n' "${C_CYAN}" "${C_RESET}" "${n}"; done
    fi

    if (( ${#WARNINGS[@]} )); then
        heading "Warnings"
        local w
        for w in "${WARNINGS[@]}"; do printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "${w}"; done
    fi

    if (( ${#NEEDS_RESTART[@]} )) && (( ! RESTART_SERVICES )); then
        heading "Services to restart"
        local svc
        for svc in "${NEEDS_RESTART[@]}"; do
            printf '  systemctl restart %s\n' "${svc}"
        done
        info ""
        info "  Re-run with --restart-services to do this automatically."
    fi

    heading "Verify"
    info "  sudo $0 --check"
    printf '\n'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    case "${MODE}" in
        list-backups)
            detect_hardware
            list_backups
            exit 0
            ;;
        check)
            detect_hardware
            detect_panel
            detect_database
            detect_nats
            printf '%sPasarGuard Server Optimizer v%s — health check%s\n' "${C_BOLD}" "${OPTIMIZER_VERSION}" "${C_RESET}"
            run_check
            exit 0
            ;;
        rollback)
            require_root
            do_rollback
            exit 0
            ;;
    esac

    require_root
    mkdir -p "${STATE_DIR}" "${REPORT_DIR}"
    touch "${LOG_FILE}" 2>/dev/null || true

    detect_hardware
    detect_panel
    detect_database
    detect_nats

    printf '%sPasarGuard Server Optimizer v%s%s\n' "${C_BOLD}" "${OPTIMIZER_VERSION}" "${C_RESET}"
    printf '%sprofile=%s  cores=%s  ram=%s  storage=%s  db=%s  virt=%s%s\n' \
        "${C_DIM}" "${PROFILE}" "${CPU_CORES}" "$(human_mb "${RAM_MB}")" \
        "$( ((IS_SSD)) && echo ssd || echo hdd )" "${DB_FLAVOR}" "${VIRT_TYPE}" "${C_RESET}"
    (( DRY_RUN )) && printf '%sDRY RUN — no changes will be written%s\n' "${C_YELLOW}" "${C_RESET}"
    check_os

    if (( ! DRY_RUN )); then
        printf '\nThis modifies kernel, systemd, storage and service configuration.\n'
        printf 'Every file is backed up to %s first.\n\n' "${BACKUP_DIR}"
        confirm "Continue?" || die "aborted by user"
    fi

    local m
    for m in ${ALL_MODULES}; do
        if is_enabled "${m}"; then
            "module_${m}"
        else
            heading "$(printf '%s' "${m}") — skipped"
        fi
    done

    (( RESTART_SERVICES )) && { heading "Restarting services"; restart_services; }

    print_summary
}

main "$@"
