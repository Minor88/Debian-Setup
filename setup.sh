#!/usr/bin/env bash
# ======================================================================
# Server setup - Оптимизированная версия
# Назначение: модульный интерактивный менеджер сервера Debian/Ubuntu
# Версия: 3.0-fixed-sftp
# Автор: рефакторинг на основе исходного setup.sh
# ======================================================================
set -euo pipefail
IFS=$'\n\t'

# -----------------------
# НАСТРОЙКИ ПО УМОЛЧАНИЮ
# -----------------------
DEFAULT_SSH_PORT=22
AUTOINSTALL_PACKAGES=true   # если false - при отсутствии пакетов будет подсказка
LOG_FILE="/var/log/server_setup.log"
SCRIPT_PATH="/usr/local/bin/setup.sh"
ALIAS_NAME="setup"

# -----------------------
# ЦВЕТА
# -----------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# -----------------------
# УТИЛИТЫ ВЫВОДА
# -----------------------
_print() { echo -e "${BLUE}ℹ️  $*${NC}"; }
_success() { echo -e "${GREEN}✅ $*${NC}"; }
_warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
_error() { echo -e "${RED}❌ $*${NC}"; }

# -----------------------
# ЛОГИРОВАНИЕ
# -----------------------
log_action() {
    local message="$1"
    local level="${2:-INFO}"
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    
    # Создаём директорию для логов с обработкой ошибок
    if [ ! -d "$log_dir" ]; then
        if ! mkdir -p "$log_dir" 2>/dev/null; then
            # Если не удалось создать директорию, пробуем альтернативный путь
            LOG_FILE="/tmp/server_setup.log"
            log_dir="/tmp"
        fi
    fi
    
    # Записываем в файл с обработкой ошибок
    if ! printf '%s - %s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE" 2>/dev/null; then
        # Если не удалось записать, пробуем /tmp
        if [ "$LOG_FILE" != "/tmp/server_setup.log" ]; then
            printf '%s - %s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "/tmp/server_setup.log" 2>/dev/null
        fi
    fi
    
    # Используем системный logger если доступен
    if command -v logger &>/dev/null; then
        logger -t "server_setup" "$message" 2>/dev/null
    fi
}

# -----------------------
# ТРАПЫ
# -----------------------
trap 'echo; _error "Прервано пользователем"; exit 2' INT

# -----------------------
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# -----------------------
require_root() {
    if [ "$EUID" -ne 0 ]; then
        _error "Пожалуйста, запустите скрипт с правами root: sudo $0"
        exit 1
    fi
}

# Универсальная функция подтверждения
ask_yes_no() {
    local prompt="$1"
    local default="${2:-}"
    local reply
    while true; do
        if [ -n "$default" ]; then
            read -rp "$prompt ($default) [y/n]: " reply
        else
            read -rp "$prompt [y/n]: " reply
        fi
        case "$reply" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            "") if [ -n "$default" ]; then
                    case "$default" in y|Y) return 0 ;; n|N) return 1 ;; esac
                fi
                ;;
            *) echo "Введите y или n." ;;
        esac
    done
}

# Чтение с дефолтом
read_input() {
    local prompt="$1"; local varname="$2"; local def="${3:-}"
    local val
    if [ -n "$def" ]; then
        read -rp "$prompt [$def]: " val
        val="${val:-$def}"
    else
        read -rp "$prompt: " val
    fi
    printf -v "$varname" '%s' "$val"
}

# Улучшенная функция проверки команд с поддержкой sbin
require_commands() {
    local -a cmds=("$@")
    local missing=()
    
    # Добавляем sbin пути в PATH если их там нет
    local current_path="$PATH"
    if [[ ":$PATH:" != *":/sbin:"* ]]; then
        PATH="/sbin:$PATH"
    fi
    if [[ ":$PATH:" != *":/usr/sbin:"* ]]; then
        PATH="/usr/sbin:$PATH"
    fi
    if [[ ":$PATH:" != *":/usr/local/sbin:"* ]]; then
        PATH="/usr/local/sbin:$PATH"
    fi
    
    for c in "${cmds[@]}"; do
        if ! command -v "$c" &>/dev/null; then
            missing+=("$c")
        fi
    done
    
    # Восстанавливаем оригинальный PATH
    PATH="$current_path"
    
    if [ ${#missing[@]} -ne 0 ]; then
        _warn "Отсутствуют команды: ${missing[*]}"
        if $AUTOINSTALL_PACKAGES; then
            # Обновляем список пакетов
            if ! apt-get update -y 2>&1 | grep -qi "err:"; then
                _warn "apt-get update завершился с предупреждениями, продолжаем..."
            fi
            
            # Пытаемся установить команды по одной
            local installed_cmds=()
            local failed_cmds=()
            
            for cmd in "${missing[@]}"; do
                # Определяем пакет по имени команды
                local pkg="$cmd"
                # Некоторые команды находятся в других пакетах
                case "$cmd" in
                    ip) pkg="iproute2" ;;
                    ss) pkg="iproute2" ;;
                    systemctl) pkg="systemd" ;;
                    *) pkg="$cmd" ;;
                esac
                
                if apt-get install -y "$pkg" 2>&1 | grep -qiE "(E:|Unable to locate|has no installation candidate)"; then
                    _warn "Не удалось установить пакет $pkg для команды $cmd"
                    failed_cmds+=("$cmd")
                else
                    # Проверяем что команда теперь доступна
                    if command -v "$cmd" &>/dev/null; then
                        installed_cmds+=("$cmd")
                    else
                        failed_cmds+=("$cmd")
                    fi
                fi
            done
            
            if [ ${#installed_cmds[@]} -gt 0 ]; then
                _success "Установлены: ${installed_cmds[*]}"
            fi
            
            if [ ${#failed_cmds[@]} -gt 0 ]; then
                _warn "Не удалось установить команды: ${failed_cmds[*]}"
                _print "Возможно нужен интернет-репозиторий"
                # Для критичных команд возвращаем ошибку
                local critical_cmds=("awk" "grep" "sed" "systemctl")
                for cmd in "${critical_cmds[@]}"; do
                    if [[ " ${failed_cmds[@]} " =~ " ${cmd} " ]]; then
                        _error "Критичная команда $cmd недоступна"
                        return 1
                    fi
                done
            fi
        else
            _error "Установите недостающие пакеты вручную: apt update && apt install -y ${missing[*]}"
            return 1
        fi
    fi
    return 0
}

# Универсальная функция проверки наличия команды (с поддержкой sbin)
command_exists() {
    local cmd="$1"
    # Проверяем в стандартных путях и sbin
    if command -v "$cmd" &>/dev/null; then
        return 0
    fi
    # Проверяем в sbin путях вручную
    for path in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$path/$cmd" ]; then
            return 0
        fi
    done
    return 1
}

# Обёртка для apt-get install, которая всегда игнорирует CD-ROM
# Использование: apt_get_install_no_cdrom --no-install-recommends --fix-missing package1 package2
apt_get_install_no_cdrom() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Acquire::cdrom::mount=/dev/null \
        -o Acquire::cdrom::always=false \
        -o Acquire::cdrom::auto=false \
        "$@"
    return $?
}

# Бэкап файла (возвращает имя бэкапа или пусто)
create_backup() {
    local file="$1"
    [ -f "$file" ] || return 1
    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp -a "$file" "$backup" && echo "$backup"
}

restore_backup() {
    local file="$1"; local backup="$2"
    if [ -f "$backup" ]; then
        cp -a "$backup" "$file"
        _success "Откат выполнен из $backup"
        return 0
    else
        _error "Бэкап не найден: $backup"
        return 1
    fi
}

# Безопасное обновление/вставка строки в конфиг: заменяет ключ или добавляет в конец
# usage: safe_set_conf /etc/ssh/sshd_config "^PasswordAuthentication" "PasswordAuthentication no"
safe_set_conf() {
    local file="$1"; local pattern="$2"; local newline="$3"
    [ -f "$file" ] || { echo "$newline" > "$file"; return 0; }
    if grep -q -E "$pattern" "$file"; then
        sed -ri "s|$pattern.*|$newline|" "$file"
    else
        echo "$newline" >> "$file"
    fi
}

# Применяет набор sysctl параметров аккуратно (меняет существующие или добавляет)
apply_sysctl_param() {
    local key="$1"; local val="$2"
    local file="/etc/sysctl.conf"
    if ! [ -f "$file" ]; then
        touch "$file"
    fi
    if grep -q -E "^${key}\\b" "$file"; then
        sed -ri "s|^${key}\\b.*|${key} = ${val}|" "$file"
    else
        echo "${key} = ${val}" >> "$file"
    fi
}

# Применяет список sysctl (перед вызовом sysctl -p)
apply_sysctl_list() {
    local key val
    for kv in "$@"; do
        key="${kv%%=*}"; val="${kv#*=}"
        apply_sysctl_param "$key" "$val"
    done
}

# Проверка формата IP
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r a b c d <<< "$ip"
        for x in $a $b $c $d; do
            if [ "$x" -lt 0 ] || [ "$x" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validate_port() {
    local p="$1"
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
        return 0
    fi
    return 1
}

validate_ssh_key() {
    local key="$1"
    # Используем ssh-keygen для проверки, если доступен
    if command_exists ssh-keygen; then
        local tmp_key
        tmp_key=$(mktemp)
        echo "$key" > "$tmp_key"
        if ssh-keygen -l -f "$tmp_key" &>/dev/null; then
            rm -f "$tmp_key"
            return 0
        fi
        rm -f "$tmp_key"
    fi
    # Более строгая регулярка как fallback
    # Формат: тип ключа (минимум 1 пробел) base64 (минимум 43 символа для ed25519, больше для других)
    if [[ "$key" =~ ^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ecdsa|ed25519)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]{43,}[[:space:]]*.*$ ]]; then
        return 0
    fi
    return 1
}

# Функция для запуска команд из sbin
run_sbin_cmd() {
    local cmd="$1"
    shift
    local args=("$@")
    
    # Ищем команду в sbin путях
    for path in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$path/$cmd" ]; then
            "$path/$cmd" "${args[@]}"
            return $?
        fi
    done
    
    # Пробуем через command -v
    if command -v "$cmd" &>/dev/null; then
        "$cmd" "${args[@]}"
        return $?
    fi
    
    _error "Команда $cmd не найдена"
    return 127
}

# Улучшенная функция для проверки/установки пакетов с sbin
check_and_install_packages() {
    local -a packages=("$@")
    local need_install=()
    
    for pkg in "${packages[@]}"; do
        # Используем dpkg-query для более надежной проверки
        # Проверяем что пакет установлен (статус "install ok installed")
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            need_install+=("$pkg")
        fi
    done
    
    if [ ${#need_install[@]} -ne 0 ]; then
        _warn "Отсутствуют пакеты: ${need_install[*]}"
        if $AUTOINSTALL_PACKAGES; then
            # Обновляем список пакетов
            local update_output
            update_output=$(apt-get update -y 2>&1)
            local update_status=$?
            
            if [ $update_status -ne 0 ]; then
                _warn "Обновление не удалось. Настройте интернет-репозитории в /etc/apt/sources.list"
            fi
            
            # Пытаемся установить пакеты по одному, чтобы не прерывать при ошибке одного
            local installed=()
            local failed=()
            
            for pkg in "${need_install[@]}"; do
                local install_output
                install_output=$(DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>&1)
                if echo "$install_output" | grep -qiE "(E:|Unable to locate|has no installation candidate|Package.*is not available)"; then
                    _warn "Пакет $pkg недоступен для установки (возможно нужен интернет-репозиторий)"
                    failed+=("$pkg")
                else
                    # Проверяем что пакет действительно установился
                    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
                        installed+=("$pkg")
                    else
                        failed+=("$pkg")
                    fi
                fi
            done
            
            if [ ${#installed[@]} -gt 0 ]; then
                _success "Установлены пакеты: ${installed[*]}"
            fi
            
            if [ ${#failed[@]} -gt 0 ]; then
                _error "Не удалось установить: ${failed[*]}"
                _print "Возможные решения:"
                _print "1. Настройте интернет-репозитории в /etc/apt/sources.list"
                _print "2. Установите пакеты вручную: apt install -y ${failed[*]}"
                
                # Для критичных пакетов возвращаем ошибку
                local critical_pkgs=("sudo" "ufw" "ipcalc")
                for pkg in "${critical_pkgs[@]}"; do
                    if [[ " ${failed[@]} " =~ " ${pkg} " ]]; then
                        _error "Критичный пакет $pkg не установлен - скрипт не может продолжить работу"
                        return 1
                    fi
                done
                
                # Для остальных пакетов продолжаем с предупреждением
                _warn "Продолжаем работу, но некоторые функции могут быть недоступны"
            fi
        else
            _error "Установите пакеты вручную: apt update && apt install -y ${need_install[*]}"
            return 1
        fi
    fi
    return 0
}

# -----------------------
# ОСНОВНЫЕ ФУНКЦИИ
# -----------------------
check_os_compatibility() {
    if [ ! -f /etc/debian_version ]; then
        _error "Этот скрипт предназначен только для Debian/Ubuntu систем"
        exit 1
    fi
    _success "ОС совместима: Debian/Ubuntu"
}

# Проверка и добавление интернет-репозиториев Debian/Ubuntu
ensure_internet_repositories() {
    local sources_file="/etc/apt/sources.list"
    local has_internet_repos=false
    local distro_codename
    local distro_id
    
    # Определяем дистрибутив
    if [ -f /etc/os-release ]; then
        distro_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        distro_codename=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    
    # Если не удалось определить, пробуем через lsb_release
    if [ -z "$distro_codename" ] && command -v lsb_release &>/dev/null; then
        distro_codename=$(lsb_release -cs 2>/dev/null)
        distro_id=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi
    
    # Если всё ещё не определили, пробуем через /etc/debian_version
    if [ -z "$distro_codename" ] && [ -f /etc/debian_version ]; then
        local debian_version
        debian_version=$(cat /etc/debian_version)
        # Для Debian пробуем определить кодовое имя
        if echo "$debian_version" | grep -qi "bookworm"; then
            distro_codename="bookworm"
            distro_id="debian"
        elif echo "$debian_version" | grep -qi "trixie"; then
            distro_codename="trixie"
            distro_id="debian"
        elif echo "$debian_version" | grep -qi "bullseye"; then
            distro_codename="bullseye"
            distro_id="debian"
        elif echo "$debian_version" | grep -qi "sid"; then
            distro_codename="sid"
            distro_id="debian"
        fi
    fi
    
    # Если всё ещё не определили, пробуем через /etc/apt/sources.list
    if [ -z "$distro_codename" ] && [ -f /etc/apt/sources.list ]; then
        # Ищем кодовое имя в существующих репозиториях
        local found_codename
        found_codename=$(grep -E "deb.*(bookworm|trixie|bullseye|sid|buster|stretch)" /etc/apt/sources.list 2>/dev/null | head -n1 | grep -oE "(bookworm|trixie|bullseye|sid|buster|stretch)" | head -n1)
        if [ -n "$found_codename" ]; then
            distro_codename="$found_codename"
            distro_id="debian"
        fi
    fi
    
    # Удаляем все DVD/CD-ROM репозитории навсегда (привода на сервере не будет)
    local cdrom_removed=false
    
    if [ -f "$sources_file" ]; then
        if grep -qiE "cdrom://|cdrom|dvd" "$sources_file" 2>/dev/null; then
            _print "Удаляем DVD/CD-ROM репозитории из sources.list..."
            # Создаём бэкап перед удалением
            cp "$sources_file" "${sources_file}.backup.before-cdrom-removal.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            # Удаляем все строки с cdrom://, cdrom, dvd (включая закомментированные)
            sed -i '/cdrom:\/\//Id' "$sources_file" 2>/dev/null || true
            sed -i '/^[[:space:]]*#.*cdrom/Id' "$sources_file" 2>/dev/null || true
            sed -i '/^[[:space:]]*deb.*cdrom/Id' "$sources_file" 2>/dev/null || true
            sed -i '/^[[:space:]]*deb.*dvd/Id' "$sources_file" 2>/dev/null || true
            cdrom_removed=true
            _success "DVD/CD-ROM репозитории удалены из sources.list"
        fi
    fi
    
    # Удаляем DVD/CD-ROM репозитории из sources.list.d
    if [ -d /etc/apt/sources.list.d ]; then
        for file in /etc/apt/sources.list.d/*.list; do
            if [ -f "$file" ] && grep -qiE "cdrom://|cdrom|dvd" "$file" 2>/dev/null; then
                _print "Удаляем DVD/CD-ROM репозитории из $(basename "$file")..."
                cp "$file" "${file}.backup.before-cdrom-removal.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                sed -i '/cdrom:\/\//Id' "$file" 2>/dev/null || true
                sed -i '/^[[:space:]]*#.*cdrom/Id' "$file" 2>/dev/null || true
                sed -i '/^[[:space:]]*deb.*cdrom/Id' "$file" 2>/dev/null || true
                sed -i '/^[[:space:]]*deb.*dvd/Id' "$file" 2>/dev/null || true
                cdrom_removed=true
                _success "DVD/CD-ROM репозитории удалены из $(basename "$file")"
            fi
        done
    fi
    
    # Очищаем кэш CD-ROM из apt lists
    rm -rf /var/lib/apt/lists/*cdrom* 2>/dev/null || true
    rm -rf /var/lib/apt/lists/*dvd* 2>/dev/null || true
    
    # Если удалили CD-ROM репозитории, обновляем кэш apt
    if [ "$cdrom_removed" = true ]; then
        _print "Обновляем кэш apt после удаления DVD/CD-ROM репозиториев..."
        apt-get update -qq 2>&1 | grep -vE "cdrom://|apt-cdrom" || true
    fi
    
    # Проверяем наличие интернет-репозиториев
    if [ -f "$sources_file" ]; then
        if grep -qE "http://|https://|ftp://" "$sources_file" 2>/dev/null; then
            has_internet_repos=true
        fi
    fi
    
    # Если нет интернет-репозиториев, добавляем стандартные
    if [ "$has_internet_repos" = false ] && [ -n "$distro_codename" ]; then
        _warn "Интернет-репозитории не найдены, добавляем стандартные..."
        
        # Создаём бэкап
        if [ -f "$sources_file" ]; then
            cp "$sources_file" "${sources_file}.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        
        # Добавляем стандартные репозитории Debian
        if [ "$distro_id" = "debian" ]; then
            {
                echo ""
                echo "# Debian internet repositories added by setup.sh"
                echo "deb http://deb.debian.org/debian $distro_codename main contrib non-free"
                echo "deb http://deb.debian.org/debian $distro_codename-updates main contrib non-free"
                # Для testing/unstable используем другой путь для security
                if [ "$distro_codename" = "sid" ] || [ "$distro_codename" = "trixie" ]; then
                    echo "deb http://deb.debian.org/debian-security $distro_codename-security main contrib non-free"
                else
                    echo "deb http://security.debian.org/debian-security $distro_codename-security main contrib non-free"
                fi
            } >> "$sources_file"
            _success "Добавлены стандартные Debian репозитории для $distro_codename"
        # Добавляем стандартные репозитории Ubuntu
        elif [ "$distro_id" = "ubuntu" ]; then
            {
                echo "# Ubuntu internet repositories added by setup.sh"
                echo "deb http://archive.ubuntu.com/ubuntu $distro_codename main restricted universe multiverse"
                echo "deb http://archive.ubuntu.com/ubuntu $distro_codename-updates main restricted universe multiverse"
                echo "deb http://security.ubuntu.com/ubuntu $distro_codename-security main restricted universe multiverse"
            } >> "$sources_file"
            _success "Добавлены стандартные Ubuntu репозитории для $distro_codename"
        else
            _warn "Не удалось определить дистрибутив, добавляем базовые Debian репозитории"
            {
                echo "# Debian internet repositories added by setup.sh"
                echo "deb http://deb.debian.org/debian stable main contrib non-free"
                echo "deb http://deb.debian.org/debian stable-updates main contrib non-free"
                echo "deb http://security.debian.org/debian-security stable-security main contrib non-free"
            } >> "$sources_file"
        fi
        
        # Обновляем список пакетов после добавления репозиториев
        _print "Обновляем список пакетов..."
        
        local update_result
        update_result=$(apt-get update -y 2>&1)
        local update_status=$?
        
        if [ $update_status -eq 0 ]; then
            _success "Список пакетов обновлён"
        else
            if echo "$update_result" | grep -qiE "(err:|E:)"; then
                _warn "Обновление списка пакетов завершилось с предупреждениями"
            else
                _success "Список пакетов обновлён"
            fi
        fi
        
        log_action "Добавлены интернет-репозитории: $distro_id $distro_codename"
        return 0
    elif [ "$has_internet_repos" = true ]; then
        _print "Интернет-репозитории уже настроены"
        return 0
    else
        _warn "Не удалось определить дистрибутив для добавления репозиториев"
        return 1
    fi
}

check_requirements() {
    require_commands awk grep sed systemctl ip ssh df free || {
        _error "Недостаточно утилит"
        exit 1
    }
    
    # СНАЧАЛА удаляем все DVD/CD-ROM репозитории (привода на сервере не будет)
    # Это должно произойти до любых операций с apt
    local sources_file="/etc/apt/sources.list"
    local cdrom_removed=false
    
    if [ -f "$sources_file" ]; then
        if grep -qiE "cdrom://|cdrom|dvd" "$sources_file" 2>/dev/null; then
            _print "Удаляем DVD/CD-ROM репозитории из sources.list..."
            cp "$sources_file" "${sources_file}.backup.before-cdrom-removal.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            sed -i '/cdrom:\/\//Id' "$sources_file" 2>/dev/null || true
            sed -i '/^[[:space:]]*#.*cdrom/Id' "$sources_file" 2>/dev/null || true
            sed -i '/^[[:space:]]*deb.*cdrom/Id' "$sources_file" 2>/dev/null || true
            sed -i '/^[[:space:]]*deb.*dvd/Id' "$sources_file" 2>/dev/null || true
            cdrom_removed=true
            _success "DVD/CD-ROM репозитории удалены из sources.list"
        fi
    fi
    
    if [ -d /etc/apt/sources.list.d ]; then
        for file in /etc/apt/sources.list.d/*.list; do
            if [ -f "$file" ] && grep -qiE "cdrom://|cdrom|dvd" "$file" 2>/dev/null; then
                _print "Удаляем DVD/CD-ROM репозитории из $(basename "$file")..."
                cp "$file" "${file}.backup.before-cdrom-removal.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                sed -i '/cdrom:\/\//Id' "$file" 2>/dev/null || true
                sed -i '/^[[:space:]]*#.*cdrom/Id' "$file" 2>/dev/null || true
                sed -i '/^[[:space:]]*deb.*cdrom/Id' "$file" 2>/dev/null || true
                sed -i '/^[[:space:]]*deb.*dvd/Id' "$file" 2>/dev/null || true
                cdrom_removed=true
                _success "DVD/CD-ROM репозитории удалены из $(basename "$file")"
            fi
        done
    fi
    
    # Очищаем кэш CD-ROM
    rm -rf /var/lib/apt/lists/*cdrom* 2>/dev/null || true
    rm -rf /var/lib/apt/lists/*dvd* 2>/dev/null || true
    
    # Если удалили CD-ROM, обновляем кэш apt
    if [ "$cdrom_removed" = true ]; then
        _print "Обновляем кэш apt после удаления DVD/CD-ROM репозиториев..."
        apt-get update -qq 2>&1 | grep -vE "cdrom://|apt-cdrom" || true
    fi
    
    # Проверяем и добавляем интернет-репозитории если нужно
    local repos_added=false
    if ensure_internet_repositories; then
        repos_added=true
    else
        _warn "Продолжаем без добавления репозиториев..."
    fi
    
    # проверка critical packages (пассивная)
    # Все эти пакеты обязательны и должны быть в репозиториях
    local critical=(openssh-server sudo passwd adduser locales ufw ipcalc)
    
    # Если репозитории только что добавлены, список пакетов уже обновлён
    if [ "$repos_added" = true ]; then
        _print "Устанавливаем критичные пакеты..."
        # Устанавливаем пакеты напрямую, без повторного обновления
        local need_install=()
        for pkg in "${critical[@]}"; do
            if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
                need_install+=("$pkg")
            fi
        done
        
        if [ ${#need_install[@]} -gt 0 ]; then
            _print "Устанавливаем: ${need_install[*]}"
            
            # Проверяем и удаляем блокировки dpkg/apt
            local lock_files=("/var/lib/dpkg/lock" "/var/lib/apt/lists/lock" "/var/cache/apt/archives/lock" "/var/lib/dpkg/lock-frontend")
            
            for lock_file in "${lock_files[@]}"; do
                if [ -f "$lock_file" ]; then
                    _warn "Обнаружена блокировка: $lock_file"
                    
                    # Проверяем, есть ли активный процесс, использующий блокировку
                    local lock_pid=""
                    if command -v lsof &>/dev/null; then
                        lock_pid=$(lsof -t "$lock_file" 2>/dev/null | head -n1 || echo "")
                    fi
                    if [ -z "$lock_pid" ] && command -v fuser &>/dev/null; then
                        lock_pid=$(fuser "$lock_file" 2>/dev/null | awk '{print $1}' | head -n1 || echo "")
                    fi
                    
                    if [ -n "$lock_pid" ] && ps -p "$lock_pid" >/dev/null 2>&1; then
                        _warn "Активный процесс использует блокировку (PID: $lock_pid)"
                        _print "Завершаем процесс..."
                        kill "$lock_pid" 2>/dev/null || true
                        sleep 2
                        # Проверяем ещё раз
                        if ps -p "$lock_pid" >/dev/null 2>&1; then
                            kill -9 "$lock_pid" 2>/dev/null || true
                            sleep 1
                        fi
                    fi
                    
                    # Удаляем блокировку если процесс не найден или завершён
                    if [ -f "$lock_file" ]; then
                        lock_pid=""
                        if command -v lsof &>/dev/null; then
                            lock_pid=$(lsof -t "$lock_file" 2>/dev/null | head -n1 || echo "")
                        fi
                        if [ -z "$lock_pid" ] && command -v fuser &>/dev/null; then
                            lock_pid=$(fuser "$lock_file" 2>/dev/null | awk '{print $1}' | head -n1 || echo "")
                        fi
                        
                        if [ -z "$lock_pid" ] || ! ps -p "$lock_pid" >/dev/null 2>&1; then
                            rm -f "$lock_file"
                            _success "Блокировка удалена: $lock_file"
                        else
                            _error "Блокировка всё ещё используется процессом (PID: $lock_pid)"
                            _print "Выполните вручную: sudo kill $lock_pid && sudo rm -f $lock_file"
                            return 1
                        fi
                    fi
                fi
            done
            
            # Проверяем интернет перед установкой
            _print "Проверка интернет-соединения..."
            if ! ping -c1 -W2 8.8.8.8 &>/dev/null && ! ping -c1 -W2 1.1.1.1 &>/dev/null; then
                if command -v curl &>/dev/null; then
                    if ! curl -s --connect-timeout 5 http://ifconfig.me >/dev/null 2>&1; then
                        _error "Интернет недоступен, не могу установить пакеты"
                        return 1
                    fi
                else
                    _error "Интернет недоступен, не могу установить пакеты"
                    return 1
                fi
            fi
            _success "Интернет доступен"
            
            # Используем timeout и DEBIAN_FRONTEND=noninteractive
            _print "Начинаем установку пакетов..."
            
            local install_output
            local install_status
            
            # Устанавливаем пакеты с выводом прогресса
            # Используем флаги для избежания интерактивных запросов и обновления списка
            export DEBIAN_FRONTEND=noninteractive
            export APT_LISTCHANGES_FRONTEND=none
            
            # Важно: используем --no-update чтобы не обновлять список пакетов (уже обновлён)
            # и --fix-missing для автоматического исправления проблем
            _print "Устанавливаем: ${need_install[*]}"
            
            # Временно отключаем строгий режим для этой команды
            set +e
            _print "Устанавливаем пакеты..."
            _print "Вывод установки:"
            echo "---"
            # Используем флаги для избежания интерактивных запросов
            export DEBIAN_FRONTEND=noninteractive
            export APT_LISTCHANGES_FRONTEND=none
            # Используем функцию-обёртку, которая игнорирует CD-ROM
            apt_get_install_no_cdrom --no-install-recommends --fix-missing "${need_install[@]}"
            install_status=$?
            echo "---"
            set -e
            
            # Проверяем результат установки
            if [ $install_status -ne 0 ]; then
                _error "Установка завершилась с ошибкой (код: $install_status)"
                return 1
            fi
            
            # Проверяем что пакеты действительно установились
            local all_installed=true
            set +e
            for pkg in "${need_install[@]}"; do
                if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
                    _warn "Пакет $pkg не установлен после установки"
                    all_installed=false
                fi
            done
            set -e
            
            if [ "$all_installed" = true ]; then
                _success "Установлены пакеты: ${need_install[*]}"
            else
                _warn "Некоторые пакеты не установлены корректно"
                return 1
            fi
        else
            _success "Все критичные пакеты уже установлены"
        fi
    else
        check_and_install_packages "${critical[@]}"
    fi
}

check_internet() {
    _print "Проверка подключения к интернету..."
    if ping -c1 -W2 8.8.8.8 &>/dev/null; then
        _success "Интернет доступен"
        return 0
    fi
    if command -v curl &>/dev/null && curl -s --connect-timeout 5 http://ifconfig.me >/dev/null 2>&1; then
        _success "Интернет доступен (curl)"
        return 0
    fi
    _warn "Интернет не доступен"
    return 1
}

check_system() {
    _print "Проверка системы..."
    if command_exists df; then
        local avail=$(df / --output=avail 2>/dev/null | tail -n1 | tr -d ' ')
        if [ -n "$avail" ]; then
            local mb=$((avail / 1024))
            if [ "$mb" -lt 1024 ]; then
                _warn "Мало свободного места: ${mb}MB"
            else
                _success "Свободное место: ${mb}MB"
            fi
        fi
    fi
    if [ -f /proc/loadavg ]; then
        local load=$(awk '{print $1}' /proc/loadavg)
        local cores=$(nproc 2>/dev/null || echo 1)
        _print "Нагрузка CPU: $load (ядер: $cores)"
    fi
    if command_exists free; then
        local free_mem=$(free -m | awk 'NR==2{print $7}')
        free_mem=${free_mem:-0}
        if [ "$free_mem" -lt 100 ]; then
            _warn "Мало свободной памяти: ${free_mem}MB"
        else
            _success "Свободная память: ${free_mem}MB"
        fi
    fi
}

# -----------------------
# СЕТЕВЫЕ ОПТИМИЗАЦИИ
# -----------------------
optimize_network() {
    _print "Оптимизация сетевых параметров (безопасно добавляем/обновляем)"
    local -a params=(
        "net.core.rmem_max=16777216"
        "net.core.wmem_max=16777216"
        "net.ipv4.tcp_rmem=4096 87380 16777216"
        "net.ipv4.tcp_wmem=4096 16384 16777216"
        "net.core.netdev_max_backlog=30000"
        "net.ipv4.tcp_max_syn_backlog=65535"
        "net.ipv4.tcp_slow_start_after_idle=0"
        "net.ipv4.tcp_syncookies=1"
        "net.ipv4.tcp_fin_timeout=10"
        "net.ipv4.tcp_tw_reuse=1"
    )
    for kv in "${params[@]}"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        apply_sysctl_param "$key" "$val"
    done
    
    # Используем run_sbin_cmd для sysctl
    if command_exists sysctl; then
        if run_sbin_cmd sysctl -p >/dev/null 2>&1; then
            _success "Sysctl применён"
            log_action "Оптимизированы sysctl параметры"
            return 0
        else
            _warn "Ошибка применения sysctl"
            return 1
        fi
    else
        _warn "sysctl не установлен"
        return 1
    fi
}

# -----------------------
# ОБНОВЛЕНИЕ СИСТЕМЫ
# -----------------------
update_system() {
    _print "Обновление системы (apt update && upgrade)"
    apt-get update -y || { _warn "apt update завершился с ошибкой"; }
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || _warn "upgrade завершился с ошибкой"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || _warn "autoremove завершился с ошибкой"
    log_action "Выполнено обновление системы"
    _success "Обновление системы завершено"
}

# -----------------------
# FIREWALL (UFW)
# -----------------------
# Проверка и установка UFW
ensure_ufw_installed() {
    if ! command_exists ufw; then
        _warn "UFW не найден"
        if $AUTOINSTALL_PACKAGES; then
            apt-get install -y ufw || { _error "Не удалось установить ufw"; return 1; }
        else
            _error "Установите ufw: apt install ufw"
            return 1
        fi
    fi
    return 0
}

# Просмотр правил UFW
view_ufw_rules() {
    ensure_ufw_installed || return 1
    echo
    _print "Статус UFW:"
    run_sbin_cmd ufw status verbose
    echo
    _print "Нумерованные правила:"
    run_sbin_cmd ufw status numbered
}

# Добавление порта
add_ufw_port() {
    ensure_ufw_installed || return 1
    local port protocol comment
    
    # Проверяем статус UFW перед добавлением порта
    local ufw_status
    ufw_status=$(run_sbin_cmd ufw status 2>/dev/null | head -n1)
    if echo "$ufw_status" | grep -qi "inactive"; then
        _warn "UFW неактивен. Правила добавлены, но не будут применяться до включения UFW."
        if ask_yes_no "Включить UFW сейчас?" "yes"; then
            if run_sbin_cmd ufw --force enable; then
                _success "UFW включён"
            else
                _warn "Не удалось включить UFW. Правила будут добавлены, но не применятся."
            fi
        fi
    fi
    
    while true; do
        read_input "Введите порт (1-65535)" port
        if validate_port "$port"; then
            break
        else
            _error "Неверный порт"
        fi
    done
    
    echo "1) TCP"
    echo "2) UDP"
    echo "3) Оба (TCP и UDP)"
    read -rp "Выберите протокол [1-3]: " proto_choice
    case "$proto_choice" in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="both" ;;
        *) protocol="tcp" ;;
    esac
    
    read_input "Комментарий (опционально)" comment ""
    
    # Если выбраны оба протокола, добавляем два отдельных правила
    if [ "$protocol" = "both" ]; then
        local tcp_ok=false
        local udp_ok=false
        
        if [ -n "$comment" ]; then
            if run_sbin_cmd ufw allow "$port/tcp" comment "${comment} (TCP)"; then
                tcp_ok=true
            fi
            if run_sbin_cmd ufw allow "$port/udp" comment "${comment} (UDP)"; then
                udp_ok=true
            fi
        else
            if run_sbin_cmd ufw allow "$port/tcp"; then
                tcp_ok=true
            fi
            if run_sbin_cmd ufw allow "$port/udp"; then
                udp_ok=true
            fi
        fi
        
        if [ "$tcp_ok" = true ] && [ "$udp_ok" = true ]; then
            _success "Порты $port/tcp и $port/udp добавлены"
            log_action "Добавлены порты UFW: $port/tcp и $port/udp${comment:+ ($comment)}"
        elif [ "$tcp_ok" = true ] || [ "$udp_ok" = true ]; then
            _warn "Добавлен только один из протоколов (TCP: $tcp_ok, UDP: $udp_ok)"
            return 1
        else
            _error "Не удалось добавить порты"
            return 1
        fi
    else
        # Один протокол
        if [ -n "$comment" ]; then
            if run_sbin_cmd ufw allow "$port/$protocol" comment "$comment"; then
                _success "Порт $port/$protocol добавлен с комментарием: $comment"
                log_action "Добавлен порт UFW: $port/$protocol ($comment)"
            else
                _error "Не удалось добавить порт"
                return 1
            fi
        else
            if run_sbin_cmd ufw allow "$port/$protocol"; then
                _success "Порт $port/$protocol добавлен"
                log_action "Добавлен порт UFW: $port/$protocol"
            else
                _error "Не удалось добавить порт"
                return 1
            fi
        fi
    fi
    
    # Проверяем статус UFW после добавления порта
    ufw_status=$(run_sbin_cmd ufw status 2>/dev/null | head -n1)
    if echo "$ufw_status" | grep -qi "inactive"; then
        _warn "ВНИМАНИЕ: UFW неактивен. Правила добавлены, но не применяются."
        _print "Используйте пункт меню '4) Включить/отключить UFW' для активации."
    fi
}

# Удаление порта (поддерживает несколько номеров через пробел)
delete_ufw_rule() {
    ensure_ufw_installed || return 1
    local rule_input
    
    echo
    _print "Текущие правила (нумерованные):"
    run_sbin_cmd ufw status numbered
    
    read -rp "Введите номер(а) правила для удаления (через пробел для нескольких): " rule_input
    
    # Разбиваем ввод на массив номеров
    # Сохраняем текущий IFS и устанавливаем пробел как разделитель
    local old_ifs="$IFS"
    IFS=' ' read -ra rule_nums <<< "$rule_input"
    IFS="$old_ifs"
    
    # Валидируем каждый номер
    for num in "${rule_nums[@]}"; do
        # Убираем возможные пробелы
        num=$(echo "$num" | xargs)
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
            _error "Неверный номер правила: $num"
            return 1
        fi
    done
    
    if [ ${#rule_nums[@]} -eq 0 ]; then
        _error "Не указано ни одного номера правила"
        return 1
    fi
    
    # Показываем какие правила будут удалены
    if [ ${#rule_nums[@]} -eq 1 ]; then
        if ! ask_yes_no "Удалить правило номер ${rule_nums[0]}?" "no"; then
            return 0
        fi
    else
        # Форматируем список правил через запятую
        local rules_list
        rules_list=$(IFS=', '; echo "${rule_nums[*]}")
        _print "Будут удалены правила: $rules_list"
        if ! ask_yes_no "Подтвердите удаление ${#rule_nums[@]} правил?" "no"; then
            return 0
        fi
    fi
    
    # Удаляем правила в обратном порядке (чтобы номера не сбились)
    # Сортируем номера по убыванию
    local -a sorted_nums=($(printf '%s\n' "${rule_nums[@]}" | sort -rn))
    local success_count=0
    local fail_count=0
    
    for num in "${sorted_nums[@]}"; do
        if run_sbin_cmd ufw --force delete "$num" 2>/dev/null; then
            _success "Правило $num удалено"
            success_count=$((success_count + 1))
            log_action "Удалено правило UFW: $num"
        else
            _warn "Не удалось удалить правило $num (возможно, уже удалено или не существует)"
            fail_count=$((fail_count + 1))
        fi
    done
    
    if [ "$success_count" -gt 0 ]; then
        _success "Удалено правил: $success_count из ${#rule_nums[@]}"
    fi
    if [ "$fail_count" -gt 0 ]; then
        _warn "Не удалось удалить: $fail_count правил"
    fi
    
    if [ "$success_count" -eq 0 ]; then
        return 1
    fi
}

# Сброс к настройкам по умолчанию
reset_ufw_defaults() {
    ensure_ufw_installed || return 1
    
    _warn "ВНИМАНИЕ: Это удалит ВСЕ текущие правила UFW!"
    if ! ask_yes_no "Вы уверены, что хотите сбросить UFW к настройкам по умолчанию?" "no"; then
        return 0
    fi
    
    if run_sbin_cmd ufw --force reset; then
        _success "UFW сброшен к настройкам по умолчанию"
        
        # Добавляем базовое правило для SSH
        if run_sbin_cmd ufw allow "$DEFAULT_SSH_PORT/tcp" comment 'SSH'; then
            _success "Добавлено правило для SSH порта $DEFAULT_SSH_PORT"
        fi
        
        if run_sbin_cmd ufw --force enable; then
            _success "UFW включён"
            log_action "UFW сброшен к настройкам по умолчанию"
        else
            _error "Не удалось включить UFW"
            return 1
        fi
    else
        _error "Не удалось сбросить UFW"
        return 1
    fi
}

# Включение/выключение UFW
toggle_ufw() {
    ensure_ufw_installed || return 1
    local status
    status=$(run_sbin_cmd ufw status 2>/dev/null | head -n1)
    
    # Проверяем статус: "Status: active" или "Status: inactive"
    if echo "$status" | grep -qiE "Status:.*active" && ! echo "$status" | grep -qi "inactive"; then
        if ask_yes_no "UFW активен. Отключить?" "no"; then
            if run_sbin_cmd ufw --force disable; then
                _success "UFW отключён"
                log_action "UFW отключён"
            else
                _error "Не удалось отключить UFW"
                return 1
            fi
        fi
    else
        if ask_yes_no "UFW неактивен. Включить?" "yes"; then
            if run_sbin_cmd ufw --force enable; then
                _success "UFW включён"
                log_action "UFW включён"
            else
                _error "Не удалось включить UFW"
                return 1
            fi
        fi
    fi
}

# Меню управления UFW
firewall_menu() {
    while true; do
        echo
        echo "=== Управление портами (UFW) ==="
        echo "1) Просмотр правил"
        echo "2) Добавить порт"
        echo "3) Удалить правило"
        echo "4) Включить/отключить UFW"
        echo "5) Сброс к настройкам по умолчанию"
        echo "6) Назад"
        read -rp "Выбор: " opt
        case "$opt" in
            1) view_ufw_rules ;;
            2) add_ufw_port ;;
            3) delete_ufw_rule ;;
            4) toggle_ufw ;;
            5) reset_ufw_defaults ;;
            6) return 0 ;;
            *) _error "Неверный выбор" ;;
        esac
    done
}

# Базовая настройка UFW (для initial setup)
configure_firewall() {
    ensure_ufw_installed || return 1
    
    _print "Текущие правила UFW:"
    local status
    status=$(run_sbin_cmd ufw status verbose 2>/dev/null || echo "inactive")
    echo "$status"
    
    # Не сбрасываем правила автоматически - только если неактивен
    if echo "$status" | grep -qi inactive; then
        _print "UFW неактивен, настраиваем базовые правила..."
        run_sbin_cmd ufw allow "$DEFAULT_SSH_PORT"/tcp comment 'SSH' || { _error "Не удалось добавить правило SSH"; return 1; }
        run_sbin_cmd ufw --force enable || { _error "Не удалось включить ufw"; return 1; }
        _success "UFW настроен и включён"
    else
        _print "UFW активен. Проверяем наличие правила для SSH порта $DEFAULT_SSH_PORT..."
        if ! echo "$status" | grep -q "$DEFAULT_SSH_PORT/tcp"; then
            if ask_yes_no "Добавить правило для SSH порта $DEFAULT_SSH_PORT?" "yes"; then
                run_sbin_cmd ufw allow "$DEFAULT_SSH_PORT"/tcp comment 'SSH' || { _error "Не удалось добавить правило SSH"; return 1; }
                _success "Правило SSH добавлено"
            fi
        else
            _success "Правило для SSH порта уже существует"
        fi
    fi
    
    log_action "Настроены правила UFW"
}

# -----------------------
# SFTP: управление SFTP в конфиге
# -----------------------
# Проверяет состояние SFTP (учитывает комментарии)
is_sftp_enabled() {
    local config_file="$1"
    [ -f "$config_file" ] || return 1
    # Ищем активную (не закомментированную) строку Subsystem sftp
    # Проверяем что строка начинается не с # и содержит Subsystem sftp
    if grep -E "^[[:space:]]*Subsystem[[:space:]]+sftp" "$config_file" 2>/dev/null | grep -qE "^[[:space:]]*[^#]"; then
        return 0
    fi
    return 1
}

# Переключает SFTP в конфиге (enable/disable)
# Гарантирует только одну строку Subsystem sftp (удаляет все дубликаты)
toggle_sftp_in_config() {
    local config_file="$1"
    local action="$2"  # "enable" или "disable"
    
    [ -f "$config_file" ] || touch "$config_file"
    
    # Удаляем ВСЕ строки Subsystem sftp (активные и закомментированные) чтобы избежать дубликатов
    # Паттерн находит: Subsystem sftp, #Subsystem sftp, # Subsystem sftp, с пробелами в начале
    sed -ri '/^[[:space:]]*#?[[:space:]]*[Ss]ubsystem[[:space:]]+[Ss][Ff][Tt][Pp]/d' "$config_file"
    
    if [ "$action" = "enable" ]; then
        # Добавляем одну строку Subsystem sftp
        echo "Subsystem sftp internal-sftp" >> "$config_file"
        safe_set_conf "$config_file" "^AllowTcpForwarding" "AllowTcpForwarding yes"
        safe_set_conf "$config_file" "^X11Forwarding" "X11Forwarding yes"
    else
        # SFTP отключён - не добавляем строку
        safe_set_conf "$config_file" "^AllowTcpForwarding" "AllowTcpForwarding no"
        safe_set_conf "$config_file" "^X11Forwarding" "X11Forwarding no"
    fi
}

# -----------------------
# SSH: проверка и безопасная настройка
# -----------------------
configure_ssh_security() {
    _print "Настройка безопасности SSH (собираем изменения и применяем один раз)"
    local ssh_conf="/etc/ssh/sshd_config"
    [ -f "$ssh_conf" ] || touch "$ssh_conf"

    local backup
    backup=$(create_backup "$ssh_conf" 2>/dev/null || echo "")

    # Проверяем доступность sshd для проверки конфигурации
    if ! command_exists sshd; then
        _warn "sshd недоступен для проверки конфигурации"
        if $AUTOINSTALL_PACKAGES; then
            apt-get install -y openssh-server || { _error "Не удалось установить openssh-server"; return 1; }
        else
            _error "Установите openssh-server: apt install openssh-server"
            return 1
        fi
    fi

    # Временный файл для сборки новой конфигурации (патчами)
    local tmp
    tmp="$(mktemp)"
    cp -a "$ssh_conf" "$tmp"

    # Сбор параметров от пользователя
    local allow_password default_pw="yes"
    if ask_yes_no "Разрешить вход по паролю (рекомендуется 'no' при наличии SSH-ключей)?" "no"; then
        allow_password="yes"
    else
        allow_password="no"
    fi

    local permit_root_choice="no"
    if ask_yes_no "Разрешать вход root по паролю? (не рекомендуется)" "no"; then
        if [ "$allow_password" = "yes" ]; then
            permit_root_choice="yes"
        else
            permit_root_choice="prohibit-password"
        fi
    else
        permit_root_choice="no"
    fi

    local enable_sftp="yes"
    if ask_yes_no "Разрешить SFTP (передача файлов)?" "yes"; then
        enable_sftp="yes"
    else
        enable_sftp="no"
    fi

    # Установка параметров в tmp (используем safe_set_conf)
    safe_set_conf "$tmp" "^Port" "Port $DEFAULT_SSH_PORT"
    safe_set_conf "$tmp" "^Protocol" "Protocol 2"
    safe_set_conf "$tmp" "^PasswordAuthentication" "PasswordAuthentication $allow_password"
    safe_set_conf "$tmp" "^PermitRootLogin" "PermitRootLogin $permit_root_choice"
    safe_set_conf "$tmp" "^PubkeyAuthentication" "PubkeyAuthentication yes"
    safe_set_conf "$tmp" "^ChallengeResponseAuthentication" "ChallengeResponseAuthentication no"
    safe_set_conf "$tmp" "^PermitEmptyPasswords" "PermitEmptyPasswords no"
    safe_set_conf "$tmp" "^MaxAuthTries" "MaxAuthTries 3"
    safe_set_conf "$tmp" "^MaxSessions" "MaxSessions 5"
    safe_set_conf "$tmp" "^ClientAliveInterval" "ClientAliveInterval 300"
    safe_set_conf "$tmp" "^ClientAliveCountMax" "ClientAliveCountMax 2"
    # SFTP handling - используем функцию
    if [ "$enable_sftp" = "yes" ]; then
        toggle_sftp_in_config "$tmp" "enable"
    else
        toggle_sftp_in_config "$tmp" "disable"
    fi

    # Проверим синтаксис перед установкой
    if run_sbin_cmd sshd -t -f "$tmp" 2>/dev/null; then
        cp -a "$tmp" "$ssh_conf"
        _success "sshd_config обновлён безопасно"
        if systemctl restart ssh >/dev/null 2>&1; then
            _success "SSH перезапущен"
            log_action "Обновлены настройки SSH"
        else
            _warn "Не удалось перезапустить SSH — попытка откатить"
            if [ -n "$backup" ]; then
                restore_backup "$ssh_conf" "$backup"
                if ! systemctl restart ssh >/dev/null 2>&1; then
                    _error "Критично: не удалось перезапустить SSH даже после отката"
                fi
            fi
        fi
    else
        _error "Ошибки в конфигурации SSH - применено не будет"
        if [ -n "$backup" ]; then
            restore_backup "$ssh_conf" "$backup"
        fi
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

# Добавление SSH ключа пользователю
add_ssh_key_for_user() {
    local username="$1"
    if ! id "$username" &>/dev/null; then
        _error "Пользователь $username не найден"
        return 1
    fi
    local user_home
    user_home=$(eval echo "~$username")
    mkdir -p "$user_home/.ssh"
    chmod 700 "$user_home/.ssh"
    chown "$username:$username" "$user_home/.ssh"
    local pubkey
    read_input "Вставьте публичный SSH ключ (или пустую строку для отмены)" pubkey
    if [ -z "$pubkey" ]; then
        _warn "Ключ не передан"
        return 0
    fi
    if ! validate_ssh_key "$pubkey"; then
        _error "Неверный формат SSH ключа"
        return 1
    fi
    echo "$pubkey" >> "$user_home/.ssh/authorized_keys"
    chmod 600 "$user_home/.ssh/authorized_keys"
    chown "$username:$username" "$user_home/.ssh/authorized_keys"
    _success "SSH ключ добавлен для $username"
    log_action "Добавлен SSH ключ для пользователя $username"
    return 0
}

# -----------------------
# ПОЛЬЗОВАТЕЛИ
# -----------------------
create_user_interactive() {
    local username
    read_input "Введите имя нового пользователя" username
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        _error "Неверное имя пользователя"
        return 1
    fi
    if id "$username" &>/dev/null; then
        _warn "Пользователь $username уже существует"
        if ! ask_yes_no "Продолжить настройку существующего пользователя $username?" "no"; then
            return 0
        fi
    else
        if ! command_exists adduser; then
            if $AUTOINSTALL_PACKAGES; then
                apt-get install -y adduser || { _error "Не удалось установить adduser"; return 1; }
            else
                _error "Установите пакет adduser"
                return 1
            fi
        fi
        # Используем run_sbin_cmd для adduser
        run_sbin_cmd adduser --gecos "" --disabled-password "$username" || { _error "Ошибка создания пользователя"; return 1; }
        _success "Пользователь $username создан"
    fi
    # Установить пароль
    _print "Установите пароль для $username"
    passwd "$username" || _warn "Не удалось установить пароль (возможно в автомоде)"
    # Добавить в sudo (NOPASSWD - по умолчанию даем)
    usermod -aG sudo "$username" || _warn "Не удалось добавить пользователя в sudo"
    local sudo_file="/etc/sudoers.d/$username"
    if [ ! -f "$sudo_file" ]; then
        echo "$username ALL=(ALL) NOPASSWD:ALL" > "$sudo_file"
        chmod 440 "$sudo_file"
    fi
    _success "Пользователь $username настроен (sudo NOPASSWD включен)"
    log_action "Создан или обновлён пользователь $username"
    # Добавить SSH ключ
    if ask_yes_no "Добавить SSH ключ для $username?" "yes"; then
        add_ssh_key_for_user "$username"
    fi
}

delete_user_interactive() {
    local username
    read_input "Введите имя пользователя для удаления" username
    if id "$username" &>/dev/null; then
        if ask_yes_no "Вы уверены, что хотите удалить $username и его домашнюю директорию?" "no"; then
            userdel -r "$username" && _success "Пользователь $username удалён" || _error "Ошибка удаления $username"
            log_action "Удалён пользователь $username"
        fi
    else
        _error "Пользователь не найден"
    fi
}

# -----------------------
# ЛОГИ
# -----------------------
# Поиск файла auth.log в разных местах
find_auth_log() {
    local possible_paths=(
        "/var/log/auth.log"
        "/var/log/secure"
        "/var/log/messages"
    )
    for path in "${possible_paths[@]}"; do
        if [ -f "$path" ] && grep -q "auth\|ssh\|login" "$path" 2>/dev/null; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# Поиск файла syslog в разных местах
find_syslog() {
    local possible_paths=(
        "/var/log/syslog"
        "/var/log/messages"
        "/var/log/system.log"
    )
    for path in "${possible_paths[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# Просмотр логов через journalctl (systemd)
view_journald_logs() {
    local log_type="$1"  # "auth" или "syslog"
    local lines="${2:-50}"
    
    if ! command_exists journalctl; then
        return 1
    fi
    
    if [ "$log_type" = "auth" ]; then
        journalctl -n "$lines" --no-pager | grep -E "(auth|ssh|login|sudo)" || journalctl -n "$lines" --no-pager
    else
        journalctl -n "$lines" --no-pager
    fi
}

view_logs_interactive() {
    while true; do
        echo
        echo "=== Просмотр логов ==="
        echo "1) auth.log / secure (последние 50)"
        echo "2) syslog / messages (последние 50)"
        echo "3) server_setup.log (последние 50)"
        echo "4) journalctl - systemd логи (последние 50)"
        echo "5) назад"
        read -rp "Выбор: " opt
        case "$opt" in
            1)
                local auth_log
                if auth_log=$(find_auth_log); then
                    _print "Просмотр: $auth_log"
                    tail -n50 "$auth_log"
                elif view_journald_logs "auth" 50 >/dev/null 2>&1; then
                    _print "Используется journalctl (systemd):"
                    view_journald_logs "auth" 50
                else
                    _error "auth.log не найден. Проверьте /var/log/auth.log, /var/log/secure или используйте journalctl"
                fi
                ;;
            2)
                local syslog_file
                if syslog_file=$(find_syslog); then
                    _print "Просмотр: $syslog_file"
                    tail -n50 "$syslog_file"
                elif view_journald_logs "syslog" 50 >/dev/null 2>&1; then
                    _print "Используется journalctl (systemd):"
                    view_journald_logs "syslog" 50
                else
                    _error "syslog не найден. Проверьте /var/log/syslog, /var/log/messages или используйте journalctl"
                fi
                ;;
            3)
                if [ -f "$LOG_FILE" ]; then
                    _print "Просмотр: $LOG_FILE"
                    tail -n50 "$LOG_FILE"
                elif [ -f "/tmp/server_setup.log" ]; then
                    _print "Просмотр: /tmp/server_setup.log"
                    tail -n50 "/tmp/server_setup.log"
                else
                    _error "server_setup.log не найден"
                fi
                ;;
            4)
                if command_exists journalctl; then
                    _print "Просмотр systemd логов (journalctl):"
                    view_journald_logs "syslog" 50
                else
                    _error "journalctl не доступен (система не использует systemd)"
                fi
                ;;
            5) return 0 ;;
            *) _error "Неверный выбор" ;;
        esac
        echo
        read -rp "Нажмите Enter чтобы продолжить..." dummy
    done
}

# -----------------------
# CRON
# -----------------------
manage_cron_interactive() {
    while true; do
        echo
        echo "1) Показать cron для root"
        echo "2) Добавить задачу (root)"
        echo "3) Редактировать crontab (root)"
        echo "4) назад"
        read -rp "Выбор: " opt
        case "$opt" in
            1) crontab -l 2>/dev/null || echo "Нет задач" ;;
            2)
                local schedule; local cmd
                read_input "Введите расписание (пример '0 2 * * *')" schedule
                read_input "Введите команду для выполнения" cmd
                (crontab -l 2>/dev/null; echo "$schedule $cmd") | crontab -
                _success "Задача добавлена"
                log_action "Добавлена cron задача: $schedule $cmd"
                ;;
            3) EDITOR=${EDITOR:-nano} crontab -e ;;
            4) return 0 ;;
            *) _error "Неверный выбор" ;;
        esac
    done
}

# -----------------------
# ПРОВЕРКА БЕЗОПАСНОСТИ
# -----------------------
security_audit_interactive() {
    echo
    _print "1) Открытые порты"
    if command_exists ss; then ss -tulpn || true
    elif command_exists netstat; then netstat -tulpn || true
    else _warn "netstat/ss не установлены"; fi

    echo
    _print "2) Последние неудачные попытки входа (auth.log)"
    local auth_log
    if auth_log=$(find_auth_log); then
        grep -i "failed" "$auth_log" | tail -n20
    elif command_exists journalctl; then
        journalctl --no-pager | grep -iE "(failed|authentication failure)" | tail -n20
    else
        echo "auth.log не найден"
    fi

    echo
    _print "3) Пользователи с SSH keys (authorized_keys в /home)"
    find /home -type f -name authorized_keys -exec sh -c 'echo "---- {} ----"; tail -n5 {}' \; 2>/dev/null || true

    echo
    _print "4) Проверка sudo NOPASSWD"
    grep -R "NOPASSWD" /etc/sudoers* 2>/dev/null || echo "NOPASSWD не найден"

    echo
    _print "5) Обновления безопасности (apt)"
    # Обновляем список пакетов перед проверкой
    if apt-get update -qq 2>/dev/null; then
        # Проверяем обновления безопасности через apt list --upgradable
        local security_updates
        security_updates=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
        
        if [ "$security_updates" -gt 0 ]; then
            _warn "Найдено обновлений безопасности: $security_updates"
            echo "Список обновлений безопасности:"
            apt list --upgradable 2>/dev/null | grep -i security | head -n20
            if [ "$security_updates" -gt 20 ]; then
                echo "... и ещё $((security_updates - 20)) обновлений"
            fi
        else
            # Альтернативный способ через apt-get upgrade --dry-run
            local upgrade_output
            upgrade_output=$(apt-get upgrade --dry-run 2>/dev/null | grep -iE "(security|upgraded)" | head -n10)
            if [ -n "$upgrade_output" ]; then
                echo "$upgrade_output"
            else
                _success "Обновления безопасности не найдены (система актуальна)"
            fi
        fi
    else
        _warn "Не удалось обновить список пакетов для проверки обновлений"
    fi

    log_action "Выполнен security audit"
    read -rp "Нажмите Enter чтобы продолжить..."
}

# -----------------------
# ИНТЕРАКТИВНОЕ МЕНЮ
# -----------------------
main_menu() {
    while true; do
        echo
        echo "=== УПРАВЛЕНИЕ СЕРВЕРОМ ==="
        echo "1) Первоначальная настройка"
        echo "2) Управление портами (UFW)"
        echo "3) Управление пользователями"
        echo "4) Управление SSH"
        echo "5) Просмотр логов"
        echo "6) Управление задачами Cron"
        echo "7) Системный мониторинг"
        echo "8) Обновление системы"
        echo "9) Проверка безопасности"
        echo "10) Настроить алиас 'setup' (копировать скрипт в $SCRIPT_PATH)"
        echo "11) Выход"
        read -rp "Выберите действие [1-11]: " choice
        case "$choice" in
            1)
                initial_setup_interactive
                ;;
            2)
                firewall_menu
                ;;
            3)
                users_menu
                ;;
            4)
                ssh_menu
                ;;
            5)
                view_logs_interactive
                ;;
            6)
                manage_cron_interactive
                ;;
            7)
                system_monitoring_menu
                ;;
            8)
                update_system
                ;;
            9)
                security_audit_interactive
                ;;
            10)
                setup_alias
                ;;
            11)
                _print "Выход..."
                exit 0
                ;;
            *)
                _error "Неверный выбор"
                ;;
        esac
    done
}

# -----------------------
# ВСПОМОГАТЕЛЬНЫЕ МЕНЮ
# -----------------------
users_menu() {
    while true; do
        echo
        echo "=== Управление пользователями ==="
        echo "1) Создать/настроить пользователя"
        echo "2) Удалить пользователя"
        echo "3) Показать список пользователей"
        echo "4) Добавить SSH ключ пользователю"
        echo "5) Назад"
        read -rp "Выбор: " opt
        case "$opt" in
            1) create_user_interactive ;;
            2) delete_user_interactive ;;
            3) cut -d: -f1 /etc/passwd | sort ;;
            4)
                local un
                read_input "Имя пользователя" un
                add_ssh_key_for_user "$un"
                ;;
            5) return 0 ;;
            *) _error "Неверный выбор" ;;
        esac
    done
}

ssh_menu() {
    while true; do
        echo
        echo "=== Управление SSH ==="
        echo "1) Настроить безопасность SSH"
        echo "2) Управление входом по паролю"
        echo "3) Управление SFTP"
        echo "4) Перезапустить SSH"
        echo "5) Показать текущий sshd_config"
        echo "6) Назад"
        read -rp "Выбор: " opt
        case "$opt" in
            1) configure_ssh_security ;;
            2)
                # toggle PasswordAuthentication
                local ssh_conf="/etc/ssh/sshd_config"
                if grep -q -E "^PasswordAuthentication[[:space:]]+no" "$ssh_conf"; then
                    safe_set_conf "$ssh_conf" "^PasswordAuthentication" "PasswordAuthentication yes"
                    systemctl restart ssh && _success "PasswordAuthentication включён" || _warn "Не удалось перезапустить ssh"
                else
                    safe_set_conf "$ssh_conf" "^PasswordAuthentication" "PasswordAuthentication no"
                    systemctl restart ssh && _success "PasswordAuthentication отключён" || _warn "Не удалось перезапустить ssh"
                fi
                ;;
            3)
                # toggle SFTP - используем функцию
                local ssh_conf="/etc/ssh/sshd_config"
                local backup
                backup=$(create_backup "$ssh_conf" 2>/dev/null)
                
                if is_sftp_enabled "$ssh_conf"; then
                    _print "SFTP включён, отключаем..."
                    toggle_sftp_in_config "$ssh_conf" "disable"
                else
                    _print "SFTP отключён, включаем..."
                    toggle_sftp_in_config "$ssh_conf" "enable"
                fi
                
                # Проверяем синтаксис перед перезапуском
                if run_sbin_cmd sshd -t -f "$ssh_conf" 2>/dev/null; then
                    if systemctl restart ssh 2>/dev/null; then
                        if is_sftp_enabled "$ssh_conf"; then
                            _success "SFTP включён"
                        else
                            _success "SFTP отключён"
                        fi
                        log_action "SFTP переключён в sshd_config"
                    else
                        _warn "Не удалось перезапустить ssh"
                        if [ -n "$backup" ]; then
                            restore_backup "$ssh_conf" "$backup"
                            _warn "Откат выполнен из бэкапа"
                        fi
                    fi
                else
                    _error "Ошибки в конфигурации SSH - откат"
                    if [ -n "$backup" ]; then
                        restore_backup "$ssh_conf" "$backup"
                    fi
                fi
                ;;
            4) systemctl restart ssh && _success "SSH перезапущен" || _warn "Не удалось перезапустить ssh" ;;
            5) grep -E "^(PasswordAuthentication|PermitRootLogin|Port|Protocol|PubkeyAuthentication|Subsystem sftp|AllowTcpForwarding|X11Forwarding)" /etc/ssh/sshd_config 2>/dev/null || _warn "sshd_config не найден" ;;
            6) return 0 ;;
            *) _error "Неверный выбор" ;;
        esac
    done
}

system_monitoring_menu() {
    while true; do
        echo
        echo "=== Системный мониторинг ==="
        echo "1) Статус системы (uptime, load)"
        echo "2) Использование диска (df -h)"
        echo "3) Использование памяти (free -h)"
        echo "4) Сетевые соединения (ss/netstat)"
        echo "5) Процессы (top 20)"
        echo "6) Назад"
        read -rp "Выбор: " opt
        case "$opt" in
            1) uptime; echo; cat /proc/loadavg ;;
            2) df -h ;;
            3) free -h ;;
            4)
                if command_exists ss; then ss -tulpn || true
                elif command_exists netstat; then netstat -tulpn || true
                else _warn "ss/netstat не найдены"; fi
                ;;
            5)
                if command_exists top; then top -bn1 | head -n20
                else ps aux --sort=-%cpu | head -n20; fi
                ;;
            6) return 0 ;;
            *) _error "Неверный выбор" ;;
        esac
    done
}

# -----------------------
# INITIAL SETUP (последовательность шагов)
# -----------------------
initial_setup_interactive() {
    _print "ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА"
    if ! ask_yes_no "Продолжить initial setup?" "no"; then
        _print "Отмена"
        return 0
    fi
    local results=()

    update_system && results+=("✅ Обновление") || results+=("⚠️ Обновление (частично)")
    if ask_yes_no "Настроить статический IP?" "no"; then
        if configure_static_ip; then
            results+=("✅ Статический IP")
        else
            results+=("⚠️ Статический IP (ошибка)")
        fi
    else
        results+=("⏭️ Статический IP (пропущено)")
    fi
    optimize_network && results+=("✅ Оптимизация сети") || results+=("⚠️ Оптимизация сети")
    configure_ssh_security && results+=("✅ SSH security") || results+=("⚠️ SSH security")
    create_user_interactive && results+=("✅ Создание пользователя") || results+=("⚠️ Создание пользователя")
    configure_firewall && results+=("✅ UFW") || results+=("⚠️ UFW")
    configure_time && results+=("✅ Время/локали") || results+=("⚠️ Время/локали")

    echo
    echo "=== РЕЗУЛЬТАТЫ INITIAL SETUP ==="
    for r in "${results[@]}"; do echo "$r"; done
    log_action "Завершён initial setup: ${results[*]}"
}

# configure_static_ip: более аккуратная версия (вставляет в /etc/network/interfaces.d/<ifname>)
configure_static_ip() {
    _warn "ВНИМАНИЕ: Изменение сети может разорвать SSH. Выполняйте локально если возможно."
    if ! ask_yes_no "Продолжить настройку статического IP?" "no"; then return 0; fi

    local interface
    interface=$(ip route | awk '/default/ {print $5; exit}')
    if [ -z "$interface" ]; then _error "Не удалось определить интерфейс"; return 1; fi
    _print "Интерфейс: $interface"

    local static_ip netmask gateway dns
    while true; do
        read_input "Введите статический IP (пример 192.168.1.100)" static_ip
        validate_ip "$static_ip" && break || _error "Неверный IP"
    done
    read_input "Введите маску (CIDR, пример 24)" netmask "24"
    if ! [[ "$netmask" =~ ^[0-9]+$ ]] || [ "$netmask" -lt 1 ] || [ "$netmask" -gt 32 ]; then _error "Неверная маска"; return 1; fi
    read_input "Введите шлюз (gateway)" gateway
    validate_ip "$gateway" || { _error "Неверный gateway"; return 1; }
    read_input "Введите DNS через пробел" dns "8.8.8.8 1.1.1.1"

    local cfgdir="/etc/network/interfaces.d"
    mkdir -p "$cfgdir"
    local cfgfile="$cfgdir/$interface.cfg"
    create_backup "$cfgfile" >/dev/null 2>&1 || true
    
    # Проверяем наличие ipcalc
    local netmask_str="255.255.255.0"
    if command_exists ipcalc; then
        netmask_str=$(run_sbin_cmd ipcalc -m "$static_ip/$netmask" 2>/dev/null | awk -F= '/Netmask/ {print $2}' || echo "255.255.255.0")
    fi
    
    cat > "$cfgfile" <<EOF
auto $interface
iface $interface inet static
    address $static_ip
    netmask $netmask_str
    gateway $gateway
    dns-nameservers $dns
EOF

    # apply
    if systemctl restart networking >/dev/null 2>&1 || /etc/init.d/networking restart >/dev/null 2>&1; then
        _success "Сетевые настройки применены"
        log_action "Настроен статический IP: $static_ip/$netmask on $interface"
        return 0
    else
        _warn "Не удалось применить настройки сети. Проверьте вручную."
        return 1
    fi
}

configure_time() {
    _print "Настройка времени и локалей"
    local time_ok=false
    local locale_ok=false
    
    if command_exists timedatectl; then
        if timedatectl set-ntp true 2>/dev/null; then
            time_ok=true
        fi
        if systemctl enable systemd-timesyncd 2>/dev/null && systemctl start systemd-timesyncd 2>/dev/null; then
            _success "NTP включён"
            time_ok=true
        fi
    fi
    
    # Проверяем наличие locale-gen альтернативными способами
    if command_exists locale-gen && [ -f /etc/locale.gen ]; then
        if sed -ri 's/^#(en_US.UTF-8)/\1/' /etc/locale.gen 2>/dev/null; then
            if run_sbin_cmd locale-gen 2>/dev/null; then
                if echo "LANG=en_US.UTF-8" > /etc/default/locale 2>/dev/null; then
                    _success "Локали настроены"
                    locale_ok=true
                fi
            fi
        fi
    elif command_exists localectl; then
        if localectl set-locale LANG=en_US.UTF-8 2>/dev/null; then
            _success "Локали настроены (localectl)"
            locale_ok=true
        fi
    fi
    
    if [ "$locale_ok" = false ]; then
        _warn "Не удалось настроить локали, пропускаем"
    fi
    
    log_action "Настройка времени и локалей завершена"
    return 0
}

# -----------------------
# АЛИАС (установить скрипт в /usr/local/bin и алиас в /root/.bashrc)
# -----------------------
setup_alias() {
    if [ ! -f "$SCRIPT_PATH" ] || ! cmp -s "$0" "$SCRIPT_PATH" 2>/dev/null; then
        cp -a "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        _success "Скрипт скопирован в $SCRIPT_PATH"
    fi
    local rc="/root/.bashrc"
    if ! grep -q "alias $ALIAS_NAME=" "$rc" 2>/dev/null; then
        {
            echo ""
            echo "# alias for server setup"
            echo "alias $ALIAS_NAME='$SCRIPT_PATH'"
        } >> "$rc"
        _success "Алиас '$ALIAS_NAME' добавлен в $rc"
        _print "Чтобы применить: source $rc"
    else
        _print "Алиас уже настроен"
    fi
}

# -----------------------
# START
# -----------------------
main() {
    # Добавляем sbin пути в PATH глобально
    export PATH="/sbin:/usr/sbin:/usr/local/sbin:$PATH"
    
    require_root
    check_os_compatibility
    check_requirements
    check_internet || _warn "Продолжим, хотя интернет недоступен"
    check_system
    # Если первый запуск - спросим про алиас
    local server_config="/root/.server_setup_done"
    if [ ! -f "$server_config" ]; then
        if ask_yes_no "Настроить алиас 'setup' для быстрого запуска?" "yes"; then
            setup_alias
        fi
        touch "$server_config" 2>/dev/null || true
    fi
    main_menu
}

main "$@"