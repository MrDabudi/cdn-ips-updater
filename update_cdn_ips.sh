#!/bin/bash

################################################################################
# Скрипт обновления списков IP-адресов CDN провайдеров
# Автор: MrDabudi
# Назначение: Получение актуальных IP CloudFlare и Gcore для настройки HAProxy
# 
# Использование:
#   ./update_cdn_ips.sh [КОМАНДА] [ОПЦИИ]
#
# Команды:
#   all              - Обновить все CDN и перезапустить все сервисы (по умолчанию)
#   cloudflare       - Обновить только CloudFlare IP
#   gcore            - Обновить только Gcore IP
#   reload           - Перезапустить только сервисы
#   help             - Показать справку
#
# Опции:
#   --dir=PATH       - Установить целевую директорию
#   --services=LIST  - Установить список сервисов (через запятую)
#   --cf-file=NAME   - Установить имя файла CloudFlare
#   --gcore-file=NAME - Установить имя файла Gcore
################################################################################

set -euo pipefail  # Остановка при ошибках, необработанных переменных и ошибках в пайпах

################################################################################
# Конфигурация и переменные
################################################################################

# Пути к файлам и директориям (можно переопределить через опции)
TARGET_DIR="/opt/cdn-ips"
CLOUDFLARE_FILE="cloudflare_ips.lst"
GCORE_FILE="gcore_ips.lst"

# URL для получения IP-адресов
readonly CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
readonly CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"
readonly GCORE_API_URL="https://api.gcore.com/cdn/public-ip-list"

# Сервисы для перезапуска (можно переопределить через опции)
SERVICES_TO_RELOAD=("haproxy" "fail2ban")

# Права доступа для директории
readonly DIR_PERMISSIONS="755"

# Идентификатор для journald логирования
readonly LOG_TAG="cdn-ips-updater"

# Флаги выполнения команд (управляются через CLI)
FETCH_CLOUDFLARE=false
FETCH_GCORE=false
RELOAD_SERVICES=false

################################################################################
# Функции помощи и справки
################################################################################

# Функция вывода справки
show_help() {
    cat << EOF
================================================================================
Скрипт обновления списков IP-адресов CDN провайдеров
================================================================================

ИСПОЛЬЗОВАНИЕ:
    $0 [КОМАНДА] [ОПЦИИ]

КОМАНДЫ:
    all              Обновить все CDN и перезапустить сервисы (по умолчанию)
    cloudflare       Обновить только CloudFlare IP
    gcore            Обновить только Gcore IP
    reload           Перезапустить только сервисы из списка
    help             Показать эту справку

ОПЦИИ:
    --dir=PATH           Установить целевую директорию
                         По умолчанию: ${TARGET_DIR}
    
    --services=LIST      Установить список сервисов через запятую
                         По умолчанию: ${SERVICES_TO_RELOAD[*]}
                         Пример: --services=haproxy,nginx,fail2ban
    
    --cf-file=NAME       Установить имя файла CloudFlare
                         По умолчанию: ${CLOUDFLARE_FILE}
    
    --gcore-file=NAME    Установить имя файла Gcore
                         По умолчанию: ${GCORE_FILE}

ПРИМЕРЫ:
    # Обновить всё с настройками по умолчанию
    $0
    
    # Обновить только CloudFlare
    $0 cloudflare
    
    # Обновить Gcore и перезапустить nginx
    $0 gcore --services=nginx
    
    # Обновить всё в другую директорию
    $0 all --dir=/custom/path
    
    # Только перезапустить сервисы
    $0 reload
    
    # Обновить CloudFlare с кастомным именем файла
    $0 cloudflare --cf-file=custom_cf.lst

ЛОГИРОВАНИЕ:
    Все действия записываются в journald с тегом: ${LOG_TAG}
    
    Просмотр логов:
        journalctl -t ${LOG_TAG} -f
        journalctl -t ${LOG_TAG} --since "1 hour ago"

CRON:
    Для автоматического обновления добавьте в crontab:
        # Каждый день в 3:00
        0 3 * * * $0 all
        
        # Каждые 6 часов
        0 */6 * * * $0 all

================================================================================
EOF
}

################################################################################
# Функции логирования
################################################################################

# Функция для логирования информационных сообщений
log_info() {
    local message="$1"
    echo "[INFO] ${message}"
    logger -t "${LOG_TAG}" -p user.info "${message}"
}

# Функция для логирования ошибок
log_error() {
    local message="$1"
    echo "[ERROR] ${message}" >&2
    logger -t "${LOG_TAG}" -p user.err "${message}"
}

# Функция для логирования успешных операций
log_success() {
    local message="$1"
    echo "[SUCCESS] ${message}"
    logger -t "${LOG_TAG}" -p user.notice "${message}"
}

################################################################################
# Парсинг аргументов командной строки
################################################################################

# Функция парсинга опций
parse_options() {
    # Если аргументов нет - выполняем всё по умолчанию
    if [ $# -eq 0 ]; then
        FETCH_CLOUDFLARE=true
        FETCH_GCORE=true
        RELOAD_SERVICES=true
        return
    fi
    
    # Парсим команды и опции
    while [ $# -gt 0 ]; do
        case "$1" in
            # Команды
            all)
                log_info "Команда: обновить всё"
                FETCH_CLOUDFLARE=true
                FETCH_GCORE=true
                RELOAD_SERVICES=true
                ;;
            cloudflare)
                log_info "Команда: обновить только CloudFlare"
                FETCH_CLOUDFLARE=true
                ;;
            gcore)
                log_info "Команда: обновить только Gcore"
                FETCH_GCORE=true
                ;;
            reload)
                log_info "Команда: только перезапуск сервисов"
                RELOAD_SERVICES=true
                ;;
            help|--help|-h)
                show_help
                exit 0
                ;;
            
            # Опции с параметрами
            --dir=*)
                TARGET_DIR="${1#*=}"
                log_info "Установлена целевая директория: ${TARGET_DIR}"
                ;;
            --services=*)
                IFS=',' read -ra SERVICES_TO_RELOAD <<< "${1#*=}"
                log_info "Установлен список сервисов: ${SERVICES_TO_RELOAD[*]}"
                ;;
            --cf-file=*)
                CLOUDFLARE_FILE="${1#*=}"
                log_info "Установлено имя файла CloudFlare: ${CLOUDFLARE_FILE}"
                ;;
            --gcore-file=*)
                GCORE_FILE="${1#*=}"
                log_info "Установлено имя файла Gcore: ${GCORE_FILE}"
                ;;
            
            # Неизвестная опция
            *)
                log_error "Неизвестная опция или команда: $1"
                echo ""
                echo "Используйте '$0 help' для справки"
                exit 1
                ;;
        esac
        shift
    done
    
    # Проверка: если не выбрано ни одно действие
    if [ "${FETCH_CLOUDFLARE}" = false ] && [ "${FETCH_GCORE}" = false ] && [ "${RELOAD_SERVICES}" = false ]; then
        log_error "Не выбрано ни одно действие. Используйте '$0 help' для справки"
        exit 1
    fi
}

################################################################################
# Получение IP-адресов CloudFlare
################################################################################

fetch_cloudflare_ips() {
    log_info "Начало получения IP-адресов CloudFlare"
    
    local temp_file
    temp_file=$(mktemp)
    
    # Получаем IPv4 адреса CloudFlare
    log_info "Загрузка IPv4 адресов CloudFlare из ${CLOUDFLARE_IPV4_URL}"
    if curl -sSf "${CLOUDFLARE_IPV4_URL}" >> "${temp_file}"; then
        log_success "IPv4 адреса CloudFlare успешно получены"
    else
        log_error "Ошибка при получении IPv4 адресов CloudFlare"
        rm -f "${temp_file}"
        return 1
    fi
    
    # Получаем IPv6 адреса CloudFlare
    log_info "Загрузка IPv6 адресов CloudFlare из ${CLOUDFLARE_IPV6_URL}"
    if curl -sSf "${CLOUDFLARE_IPV6_URL}" >> "${temp_file}"; then
        log_success "IPv6 адреса CloudFlare успешно получены"
    else
        log_error "Ошибка при получении IPv6 адресов CloudFlare"
        rm -f "${temp_file}"
        return 1
    fi
    
    # Сохраняем результат во временную переменную
    echo "${temp_file}"
}

################################################################################
# Получение IP-адресов Gcore
################################################################################

fetch_gcore_ips() {
    log_info "Начало получения IP-адресов Gcore"
    
    local temp_file
    temp_file=$(mktemp)
    
    # Получаем JSON с IP адресами Gcore
    log_info "Загрузка IP адресов Gcore из API: ${GCORE_API_URL}"
    local json_response
    if json_response=$(curl -sSf "${GCORE_API_URL}"); then
        log_success "Данные Gcore успешно получены из API"
    else
        log_error "Ошибка при получении данных из API Gcore"
        rm -f "${temp_file}"
        return 1
    fi
    
    # Парсим JSON и извлекаем IP адреса (поддержка как IPv4, так и IPv6)
    log_info "Парсинг JSON ответа Gcore"
    if command -v jq &> /dev/null; then
        # Используем jq если доступен (более надежный метод)
        echo "${json_response}" | jq -r '.addresses[]' > "${temp_file}"
        log_info "Использован jq для парсинга JSON"
    else
        # Альтернативный метод с grep (если jq не установлен)
        echo "${json_response}" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?|([0-9a-fA-F:]+)/[0-9]{1,3}' > "${temp_file}"
        log_info "Использован grep для парсинга JSON (jq не найден)"
    fi
    
    if [ -s "${temp_file}" ]; then
        log_success "IP адреса Gcore успешно обработаны"
    else
        log_error "Не удалось извлечь IP адреса из ответа Gcore"
        rm -f "${temp_file}"
        return 1
    fi
    
    # Сохраняем результат во временную переменную
    echo "${temp_file}"
}

################################################################################
# Создание директории и сохранение файлов
################################################################################

prepare_directory() {
    log_info "Подготовка целевой директории: ${TARGET_DIR}"
    
    # Создаем директорию если она не существует
    if [ ! -d "${TARGET_DIR}" ]; then
        log_info "Директория ${TARGET_DIR} не существует, создаем..."
        if mkdir -p "${TARGET_DIR}"; then
            log_success "Директория ${TARGET_DIR} успешно создана"
        else
            log_error "Ошибка при создании директории ${TARGET_DIR}"
            return 1
        fi
    else
        log_info "Директория ${TARGET_DIR} уже существует"
    fi
    
    # Устанавливаем права доступа
    log_info "Установка прав доступа ${DIR_PERMISSIONS} для ${TARGET_DIR}"
    if chmod "${DIR_PERMISSIONS}" "${TARGET_DIR}"; then
        log_success "Права доступа успешно установлены"
    else
        log_error "Ошибка при установке прав доступа"
        return 1
    fi
}

save_ip_file() {
    local temp_file="$1"
    local target_filename="$2"
    local full_path="${TARGET_DIR}/${target_filename}"
    
    log_info "Сохранение IP-адресов в файл: ${full_path}"
    
    # Копируем временный файл в целевую директорию
    if mv "${temp_file}" "${full_path}"; then
        log_success "Файл ${target_filename} успешно сохранен"
        
        # Подсчитываем количество записей для логирования
        local ip_count
        ip_count=$(wc -l < "${full_path}")
        log_info "Всего IP-адресов в ${target_filename}: ${ip_count}"
    else
        log_error "Ошибка при сохранении файла ${target_filename}"
        return 1
    fi
}

################################################################################
# Перезапуск сервисов
################################################################################

reload_service() {
    local service_name="$1"
    
    log_info "Проверка статуса сервиса: ${service_name}"
    
    # Проверяем, запущен ли сервис
    if systemctl is-active --quiet "${service_name}"; then
        log_info "Сервис ${service_name} активен, выполняем reload"
        
        # Выполняем плавный перезапуск (reload)
        if systemctl reload "${service_name}"; then
            log_success "Сервис ${service_name} успешно перезагружен (reload)"
        else
            log_error "Ошибка при reload сервиса ${service_name}"
            return 1
        fi
    else
        log_info "Сервис ${service_name} не запущен, пропускаем reload"
    fi
}

reload_all_services() {
    log_info "Начало проверки и перезапуска сервисов"
    
    # Перебираем все сервисы из массива
    for service in "${SERVICES_TO_RELOAD[@]}"; do
        reload_service "${service}"
    done
    
    log_success "Проверка и перезапуск сервисов завершены"
}

################################################################################
# Основная логика выполнения
################################################################################

main() {
    log_info "=========================================="
    log_info "Запуск скрипта обновления CDN IP-адресов"
    log_info "=========================================="
    
    # Парсим аргументы командной строки
    parse_options "$@"
    
    # Выводим текущие настройки
    log_info "Текущие настройки:"
    log_info "  - Целевая директория: ${TARGET_DIR}"
    log_info "  - Файл CloudFlare: ${CLOUDFLARE_FILE}"
    log_info "  - Файл Gcore: ${GCORE_FILE}"
    log_info "  - Сервисы для reload: ${SERVICES_TO_RELOAD[*]}"
    
    # Подготавливаем директорию если будем получать IP
    if [ "${FETCH_CLOUDFLARE}" = true ] || [ "${FETCH_GCORE}" = true ]; then
        if prepare_directory; then
            log_success "Директория подготовлена"
        else
            log_error "Критическая ошибка при подготовке директории"
            exit 1
        fi
    fi
    
    # Получаем и сохраняем IP CloudFlare если нужно
    if [ "${FETCH_CLOUDFLARE}" = true ]; then
        log_info "=========================================="
        log_info "Обработка CloudFlare IP"
        log_info "=========================================="
        
        local cf_temp_file
        if cf_temp_file=$(fetch_cloudflare_ips); then
            log_success "CloudFlare IP успешно получены"
            
            if save_ip_file "${cf_temp_file}" "${CLOUDFLARE_FILE}"; then
                log_success "Файл CloudFlare сохранен"
            else
                log_error "Критическая ошибка при сохранении файла CloudFlare"
                exit 1
            fi
        else
            log_error "Критическая ошибка при получении CloudFlare IP"
            exit 1
        fi
    fi
    
    # Получаем и сохраняем IP Gcore если нужно
    if [ "${FETCH_GCORE}" = true ]; then
        log_info "=========================================="
        log_info "Обработка Gcore IP"
        log_info "=========================================="
        
        local gcore_temp_file
        if gcore_temp_file=$(fetch_gcore_ips); then
            log_success "Gcore IP успешно получены"
            
            if save_ip_file "${gcore_temp_file}" "${GCORE_FILE}"; then
                log_success "Файл Gcore сохранен"
            else
                log_error "Критическая ошибка при сохранении файла Gcore"
                exit 1
            fi
        else
            log_error "Критическая ошибка при получении Gcore IP"
            exit 1
        fi
    fi
    
    # Перезапускаем сервисы если нужно
    if [ "${RELOAD_SERVICES}" = true ]; then
        log_info "=========================================="
        log_info "Перезапуск сервисов"
        log_info "=========================================="
        reload_all_services
    fi
    
    log_info "=========================================="
    log_success "Скрипт успешно завершен!"
    log_info "=========================================="
}

################################################################################
# ТОЧКА ВХОДА
################################################################################

# Запускаем основную функцию с передачей всех аргументов
main "$@"
