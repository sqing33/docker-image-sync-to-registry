#!/bin/bash

# sync_images.sh
# 这个脚本用于同步 Docker Hub 镜像到本地私有仓库
# 它会定期从 Docker Hub 拉取镜像并推送到本地仓库。
# 架构特定的标签 (如 image:tag-linux-amd64) 将保留在私有仓库中。

# 添加日志函数
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color_start=""
    local color_end="\033[0m" # Reset color

    case "$level" in
        "INFO")
            color_start="\033[0;32m" # Green
            prefix="✨ INFO"
            ;;
        "WARN")
            color_start="\033[0;33m" # Yellow
            prefix="⚠️ WARN"
            ;;
        "ERROR")
            color_start="\033[0;31m" # Red
            prefix="❌ ERROR"
            ;;
        *)
            prefix="[LOG]" # Default for unknown levels
            ;;
    esac

    echo -e "${color_start}${timestamp} ${prefix} ${message}${color_end}" >> "$SYNC_LOG_FILE"
    echo -e "${color_start}${timestamp} ${prefix} ${message}${color_end}"
}

# --- 配置部分 ---
REGISTRY_URL="${REGISTRY_URL}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 4 * * *}"
SYNC_ON_START="${SYNC_ON_START:-true}"
TARGET_ARCH="${TARGET_ARCH:-linux/amd64}"
REMOVE_LIBRARY_PREFIX_ON_LOCAL="${REMOVE_LIBRARY_PREFIX_ON_LOCAL:-true}"
PYTHON_SCRIPT_PATH="/app/docker_hub_crawler.py"
IMAGE_LIST_DIR="/app/output"
LOG_DIR="/var/log"
MAX_PAGES_PER_CATEGORY="${MAX_PAGES_PER_CATEGORY:-1}"
CUSTOM_IMAGES_FILE="/app/custom_images.txt"
CRAWL_AFTER_CUSTOM_IMAGES="${CRAWL_AFTER_CUSTOM_IMAGES:-false}" # 新增参数：拉取custom_images镜像之后是否继续爬取DockerHub

# --- 辅助变量 ---
OLD_IFS="$IFS"
IFS=","
set -- $TARGET_ARCH
TARGET_ARCHS=""
for arch_val; do
    TARGET_ARCHS="$TARGET_ARCHS $arch_val"
done
IFS="$OLD_IFS"
TARGET_ARCHS=$(echo "$TARGET_ARCHS" | xargs) # 去除首尾空格

# DOCKER_REGISTRY_HOST_FOR_CLI 用于 docker tag/push 等命令，不含协议
# REGISTRY_URL_FOR_API_CALLS 用于 API 调用，会处理协议
DOCKER_REGISTRY_HOST_FOR_CLI=""
if [ -n "$REGISTRY_URL" ]; then
    DOCKER_REGISTRY_HOST_FOR_CLI=$(echo "$REGISTRY_URL" | sed -e 's|^[^/]*://||' -e 's|/.*$||')
fi


CRON_LOG_FILE="${LOG_DIR}/cron.log"
SYNC_LOG_FILE="${LOG_DIR}/sync_images_activity.log"
PYTHON_CRAWLER_LOG_FILE="${LOG_DIR}/docker_hub_crawler_output.log"

# --- 依赖检查和设置 ---
ensure_dependencies() {
    mkdir -p "$IMAGE_LIST_DIR" "$LOG_DIR"
    touch "$CRON_LOG_FILE" "$SYNC_LOG_FILE" "$PYTHON_CRAWLER_LOG_FILE"

    if [ -z "$REGISTRY_URL" ]; then
        log_message "ERROR" "REGISTRY_URL 未设置。"
        exit 1
    fi
    if [ -z "$DOCKER_REGISTRY_HOST_FOR_CLI" ]; then
        log_message "ERROR" "无法从 REGISTRY_URL ('$REGISTRY_URL') 解析用于 Docker CLI 的主机名。"
        exit 1
    fi
    
    if ! command -v jq > /dev/null; then
        log_message "INFO" "尝试安装 jq..."
        if ! apk add --no-cache jq > /dev/null 2>&1; then
            log_message "ERROR" "jq 安装失败。请手动安装。"
            exit 1
        else
            log_message "INFO" "jq 安装成功。"
        fi
    fi

    if ! command -v curl > /dev/null; then
        log_message "INFO" "尝试安装 curl..."
        if ! apk add --no-cache curl > /dev/null 2>&1; then
            log_message "ERROR" "curl 安装失败。请手动安装。"
            exit 1
        else
            log_message "INFO" "curl 安装成功。"
        fi
    fi
    
    if ! command -v docker > /dev/null; then
        log_message "ERROR" "docker CLI 未安装或不在PATH中。"
        exit 1
    fi
    
    if [ ! -f "$PYTHON_SCRIPT_PATH" ]; then
        log_message "ERROR" "Python 爬虫脚本 '$PYTHON_SCRIPT_PATH' 未找到。"
        exit 1
    fi
}

log_config() {
    log_message "INFO" "--- 配置信息 ---"
    log_message "INFO" "镜像仓库 URL (用于 API 调用): $REGISTRY_URL"
    log_message "INFO" "镜像仓库主机 (用于 Docker CLI): $DOCKER_REGISTRY_HOST_FOR_CLI"
    log_message "INFO" "定时任务计划: $CRON_SCHEDULE"
    log_message "INFO" "启动时同步: $SYNC_ON_START"
    log_message "INFO" "目标架构: '$TARGET_ARCHS'"
    log_message "INFO" "移除 'library/' 前缀: $REMOVE_LIBRARY_PREFIX_ON_LOCAL"
    log_message "INFO" "Python 脚本: $PYTHON_SCRIPT_PATH"
    log_message "INFO" "镜像列表目录: $IMAGE_LIST_DIR"
    log_message "INFO" "每个类别最大页数: $MAX_PAGES_PER_CATEGORY"
    log_message "INFO" "自定义镜像文件: $CUSTOM_IMAGES_FILE"
    log_message "INFO" "自定义镜像后继续爬取: $CRAWL_AFTER_CUSTOM_IMAGES"
    log_message "INFO" "日志文件: $CRON_LOG_FILE, $SYNC_LOG_FILE, $PYTHON_CRAWLER_LOG_FILE"
    log_message "INFO" "----------------"
}

get_arch_image_config_digest() {
    local full_image_name="$1" # 格式可以是 docker.io/xxx 或 DOCKER_REGISTRY_HOST_FOR_CLI/xxx
    local target_arch="$2"
    local manifest_json
    local platform_manifest_entry_digest
    local image_config_digest_value=""

    manifest_json=$(docker manifest inspect "$full_image_name" 2>/dev/null)

    if [ -z "$manifest_json" ]; then
        echo ""
        return
    fi

    is_manifest_list=$(echo "$manifest_json" | jq 'if type == "array" then false else (.manifests | type == "array" and length > 0) end' 2>/dev/null)

    if [ "$is_manifest_list" = "true" ]; then
        platform_manifest_entry_digest=$(echo "$manifest_json" | jq -r \
            --arg OS_ARG "$(echo "$target_arch" | cut -d/ -f1)" \
            --arg ARCH_ARG "$(echo "$target_arch" | cut -d/ -f2)" \
            '.manifests[]? | select(.platform.os == $OS_ARG and .platform.architecture == $ARCH_ARG) | .digest' 2>/dev/null)

        if [ -n "$platform_manifest_entry_digest" ] && [ "$platform_manifest_entry_digest" != "null" ] && [ "$platform_manifest_entry_digest" != '""' ]; then
            local image_name_base
            if echo "$full_image_name" | grep -q '@sha256:'; then
                 image_name_base=$(echo "$full_image_name" | cut -d@ -f1)
            else
                 image_name_base=$(echo "$full_image_name" | cut -d: -f1)
            fi
            
            local specific_image_manifest_json
            specific_image_manifest_json=$(docker manifest inspect "${image_name_base}@${platform_manifest_entry_digest}" 2>/dev/null)
            
            if [ -n "$specific_image_manifest_json" ]; then
                image_config_digest_value=$(echo "$specific_image_manifest_json" | jq -r '.config.digest // ""' 2>/dev/null)
            fi
        fi
            else # 不是 manifest 列表，视为单个 manifest
                local actual_os=$(echo "$manifest_json" | jq -r '.platform.os // ""' 2>/dev/null)
                local actual_arch=$(echo "$manifest_json" | jq -r '.platform.architecture // ""' 2>/dev/null)
                local target_os_val=$(echo "$target_arch" | cut -d/ -f1)
                local target_arch_val=$(echo "$target_arch" | cut -d/ -f2)

        if [ "$actual_os" = "$target_os_val" ] && [ "$actual_arch" = "$target_arch_val" ]; then
            image_config_digest_value=$(echo "$manifest_json" | jq -r '.config.digest // ""' 2>/dev/null)
        fi
    fi
    
    if [ -z "$image_config_digest_value" ] || [ "$image_config_digest_value" == "null" ] || [ "$image_config_digest_value" == '""' ]; then
        image_config_digest_value="" 
    fi
    echo "$image_config_digest_value"
}

sync_images() {
    log_message "INFO" "🚀　开始镜像同步..."
    mkdir -p "$IMAGE_LIST_DIR"
    
    local LATEST_FILE
    local crawl_needed=false

    if [ -f "$CUSTOM_IMAGES_FILE" ]; then
        log_message "INFO" "使用自定义镜像列表: $CUSTOM_IMAGES_FILE"
        LATEST_FILE="$CUSTOM_IMAGES_FILE"
        if [ "$CRAWL_AFTER_CUSTOM_IMAGES" = "true" ]; then
            log_message "INFO" "CRAWL_AFTER_CUSTOM_IMAGES 为 true，将在处理自定义镜像后继续爬取 Docker Hub。"
            crawl_needed=true
        else
            log_message "INFO" "CRAWL_AFTER_CUSTOM_IMAGES 为 false，将只使用自定义镜像列表。"
        fi
    else
        log_message "INFO" "未找到自定义镜像列表，将使用爬虫获取。"
        crawl_needed=true
    fi

    if [ "$crawl_needed" = "true" ]; then
        log_message "INFO" "执行 Python 爬虫脚本: $PYTHON_SCRIPT_PATH (MAX_PAGES_PER_CATEGORY=$MAX_PAGES_PER_CATEGORY)"
        if ! MAX_PAGES_PER_CATEGORY="$MAX_PAGES_PER_CATEGORY" python3 "$PYTHON_SCRIPT_PATH" > "$PYTHON_CRAWLER_LOG_FILE" 2>&1; then
            log_message "ERROR" "Python 脚本执行失败。详情请查看 $PYTHON_CRAWLER_LOG_FILE"
            return 1
        fi
        log_message "INFO" "Python 脚本执行完成。"
        # 如果有自定义镜像文件，则将爬取结果追加到自定义镜像文件，否则直接使用爬取结果
        if [ -f "$CUSTOM_IMAGES_FILE" ] && [ "$CRAWL_AFTER_CUSTOM_IMAGES" = "true" ]; then
            local crawled_file=$(ls -t "${IMAGE_LIST_DIR}/docker_images_"*.txt 2>/dev/null | head -n1)
            if [ -n "$crawled_file" ] && [ -f "$crawled_file" ]; then
                log_message "INFO" "将爬取结果 ($crawled_file) 追加到自定义镜像列表 ($CUSTOM_IMAGES_FILE)。"
                cat "$crawled_file" >> "$CUSTOM_IMAGES_FILE"
                rm "$crawled_file" # 清理临时爬取文件
            fi
        fi
    fi

    # 最终使用的镜像列表文件
    if [ -f "$CUSTOM_IMAGES_FILE" ]; then
        LATEST_FILE="$CUSTOM_IMAGES_FILE"
    else
        LATEST_FILE=$(ls -t "${IMAGE_LIST_DIR}/docker_images_"*.txt 2>/dev/null | head -n1)
    fi

    if [ -z "$LATEST_FILE" ] || [ ! -f "$LATEST_FILE" ]; then
        log_message "ERROR" "未找到有效的镜像列表文件 (期望在 $IMAGE_LIST_DIR 下找到 docker_images_*.txt 或 $CUSTOM_IMAGES_FILE)。"
        return 1
    fi
    log_message "INFO" "最终使用的镜像列表: $LATEST_FILE"
    
    local current_temp_dir
    current_temp_dir=$(mktemp -d)
    trap 'log_message "INFO" "🗑️ 清理临时目录: $current_temp_dir"; rm -rf "$current_temp_dir"; trap - EXIT INT TERM' EXIT INT TERM

    cat "$LATEST_FILE" | while IFS= read -r image_from_crawler || [ -n "$image_from_crawler" ]; do
        if [ -z "$image_from_crawler" ]; then
            continue
        fi

        image_name_part=$(echo "$image_from_crawler" | cut -d: -f1)
        image_tag_part=$(echo "$image_from_crawler" | cut -d: -f2)
        local image_tag
        if [ "$image_name_part" == "$image_tag_part" ] || [ -z "$image_tag_part" ]; then 
            image_tag="latest"
        else
            image_tag="$image_tag_part"
        fi
        
        local hub_image_name_ns image_name_for_local_repo is_official_image
        if ! echo "$image_name_part" | grep -q /; then
            hub_image_name_ns="library/${image_name_part}"
            image_name_for_local_repo="$image_name_part"
            is_official_image=true
        else
            hub_image_name_ns="$image_name_part"
            image_name_for_local_repo="$image_name_part"
            is_official_image=false
        fi

        local actual_local_repo_path
        if [ "$is_official_image" = true ] && [ "$REMOVE_LIBRARY_PREFIX_ON_LOCAL" = "true" ]; then
            actual_local_repo_path="$image_name_for_local_repo"
        else
            actual_local_repo_path="$hub_image_name_ns"
        fi
        
        # hub_image_full 是 Docker Hub 上的源镜像 (格式: docker.io/...)
        local hub_image_full="docker.io/${hub_image_name_ns}:${image_tag}"
        # local_image_full 是私有仓库中多架构 manifest 的目标标签 (格式: DOCKER_REGISTRY_HOST_FOR_CLI/...)
        local local_image_full="${DOCKER_REGISTRY_HOST_FOR_CLI}/${actual_local_repo_path}:${image_tag}"

        log_message "INFO" "处理镜像: $hub_image_full -> $local_image_full"

        local archs_to_sync_file="$current_temp_dir/archs_to_sync_${image_name_part//\//_}_${image_tag}.txt"
        local arch_images_for_manifest_file="$current_temp_dir/arch_images_for_manifest_${image_name_part//\//_}_${image_tag}.txt"
        >"$archs_to_sync_file"; >"$arch_images_for_manifest_file"

        local needs_sync_overall=false
        for target_arch_loop in $TARGET_ARCHS; do
            log_message "INFO" "🔍 检查架构 $target_arch_loop for $hub_image_full..."
            local retry_count=0
            local max_retries=3 
            local hub_config_digest=""
            local get_digest_success=false

            while [ "$retry_count" -lt "$max_retries" ]; do
                hub_config_digest=$(get_arch_image_config_digest "$hub_image_full" "$target_arch_loop")
                if [ -n "$hub_config_digest" ]; then
                    get_digest_success=true
                    break 
                fi
                retry_count=$((retry_count + 1))
                if [ "$retry_count" -lt "$max_retries" ]; then
                    log_message "WARN" "无法获取 Docker Hub 镜像 $hub_image_full 的 $target_arch_loop Config Digest (尝试 $retry_count/$max_retries)。将在5秒后重试..."
                    sleep 5
                else
                    log_message "ERROR" "在 $max_retries 次尝试后，仍无法获取 Docker Hub 镜像 $hub_image_full 的 $target_arch_loop Config Digest。"
                fi
            done

            if [ "$get_digest_success" = "false" ]; then
                log_message "WARN" "由于无法获取 Hub Digest，跳过 $hub_image_full 的 $target_arch_loop 架构。"
                continue 
            fi
            
            # local_image_full 已经是不带协议的格式
            local_config_digest=$(get_arch_image_config_digest "$local_image_full" "$target_arch_loop") 
            if [ "$hub_config_digest" == "$local_config_digest" ]; then
                log_message "INFO" "✅　本地镜像 $local_image_full ($target_arch_loop) 已是最新版本 (Digest: $hub_config_digest)。"
            else
                log_message "INFO" "🔄　本地镜像 $local_image_full ($target_arch_loop) 需要更新 (Hub Digest: $hub_config_digest, Local Digest: ${local_config_digest:-'不存在或无法获取'})。"
                echo "$target_arch_loop" >> "$archs_to_sync_file"
                needs_sync_overall=true
            fi
        done

        if [ "$needs_sync_overall" = "false" ]; then
            log_message "INFO" "镜像 $hub_image_full 所有目标架构均已是最新版本或无需更新。跳过。"
            continue
        fi
        
        arch_count=$(wc -l < "$archs_to_sync_file" | xargs)
        if [ "$arch_count" -eq 0 ]; then
             log_message "INFO" "没有需要同步的架构 (可能由于获取 Hub Digest 失败后跳过)，跳过 $hub_image_full。"
             continue
        fi
        log_message "INFO" "开始同步 $hub_image_full 的 $arch_count 个架构..."

        local any_arch_pushed_successfully=false
        while IFS= read -r current_target_arch_sync; do
            log_message "INFO" "处理架构: $current_target_arch_sync for $hub_image_full"
            
            log_message "INFO" "⬇️　拉取 $hub_image_full (架构: $current_target_arch_sync)..."
            if ! docker pull --platform "$current_target_arch_sync" "$hub_image_full"; then
                log_message "ERROR" "拉取 $hub_image_full (架构: $current_target_arch_sync) 失败。"
                continue
            fi
            
            # local_image_arch_tagged 使用不带协议的 local_image_full
            local local_image_arch_tagged="${local_image_full}-${current_target_arch_sync//\//-}" # 格式: DOCKER_REGISTRY_HOST_FOR_CLI/image:tag-arch
            
            log_message "INFO" "🏷️　标记 $hub_image_full 为 $local_image_arch_tagged"
            if ! docker tag "$hub_image_full" "$local_image_arch_tagged"; then
                log_message "ERROR" "标记 $hub_image_full 为 $local_image_arch_tagged 失败。"
                docker rmi "$hub_image_full" 2>/dev/null || true
                continue
            fi

            log_message "INFO" "⬆️　推送带架构的镜像 $local_image_arch_tagged 到私有仓库..."
            if ! docker push "$local_image_arch_tagged"; then
                log_message "ERROR" "推送带架构的镜像 $local_image_arch_tagged 失败。"
                docker rmi "$local_image_arch_tagged" 2>/dev/null || true
                docker rmi "$hub_image_full" 2>/dev/null || true
                continue
            fi
            
            log_message "INFO" "✅　成功推送 $local_image_arch_tagged. 添加到 manifest 创建列表。"
            echo "$local_image_arch_tagged" >> "$arch_images_for_manifest_file"
            any_arch_pushed_successfully=true

            docker rmi "$hub_image_full" 2>/dev/null || true 
        done < "$archs_to_sync_file"

        if [ "$any_arch_pushed_successfully" = true ] && [ -s "$arch_images_for_manifest_file" ]; then
            log_message "INFO" "📦　准备为 $local_image_full 创建多架构 manifest..."
            MANIFEST_IMAGES_ARGS=$(cat "$arch_images_for_manifest_file" | xargs) # 包含 DOCKER_REGISTRY_HOST_FOR_CLI/... 格式的镜像
            log_message "INFO" "使用已推送的架构镜像创建 manifest: $MANIFEST_IMAGES_ARGS"

            log_message "INFO" "尝试移除旧 manifest list: $local_image_full (如果存在)"
            docker manifest rm "$local_image_full" 2>/dev/null || true # local_image_full 是 DOCKER_REGISTRY_HOST_FOR_CLI/... 格式

            if ! docker manifest create "$local_image_full" $MANIFEST_IMAGES_ARGS; then
                log_message "ERROR" "创建 manifest $local_image_full 失败。引用的镜像: $MANIFEST_IMAGES_ARGS"
            else
                log_message "INFO" "✅　成功创建本地 manifest list: $local_image_full。开始推送..."
                if ! docker manifest push "$local_image_full"; then
                    log_message "ERROR" "推送 manifest $local_image_full 失败。"
                    docker manifest rm "$local_image_full" 2>/dev/null || true
                else
                    log_message "INFO" "🎉　成功创建并推送多架构 manifest: $local_image_full"
                fi
            fi
        elif [ "$arch_count" -gt 0 ]; then 
             log_message "WARN" "$hub_image_full 的部分或所有待同步架构未能成功推送到仓库，无法创建 manifest。"
        fi

        log_message "INFO" "🧹　清理本地带架构后缀的镜像: $local_image_full..."
        if [ -f "$arch_images_for_manifest_file" ]; then
            while IFS= read -r arch_image_to_remove_local; do
                log_message "INFO" "移除本地镜像: $arch_image_to_remove_local"
                docker rmi "$arch_image_to_remove_local" 2>/dev/null || true
            done < "$arch_images_for_manifest_file"
        fi
        rm -f "$archs_to_sync_file" "$arch_images_for_manifest_file"
    done < "$LATEST_FILE"
    log_message "INFO" "✅　镜像同步执行完毕。"
}

# --- 主逻辑 ---
ensure_dependencies
log_config

if [ "$1" = "sync" ]; then
    sync_images
    exit 0
fi

if [ "$SYNC_ON_START" = "true" ]; then
    log_message "INFO" "SYNC_ON_START 为 true，执行首次同步..."
    sync_images
    log_message "INFO" "首次同步执行完毕。"
fi

if command -v crond > /dev/null; then
    CRONTAB_FILE="/var/spool/cron/crontabs/root" 
    log_message "INFO" "设置 cron 任务: '$CRON_SCHEDULE /app/sync_images.sh sync >> $SYNC_LOG_FILE 2>&1' in $CRONTAB_FILE"
    touch "$CRONTAB_FILE" 
    echo "" > "$CRONTAB_FILE" 
    echo "$CRON_SCHEDULE /app/sync_images.sh sync >> $SYNC_LOG_FILE 2>&1" >> "$CRONTAB_FILE"
    log_message "INFO" "启动 crond 服务 (日志输出到 $CRON_LOG_FILE)..."
    crond -b -S -l 8 -L "$CRON_LOG_FILE" 
else
    log_message "WARN" "crond 未找到，无法设置定时任务。"
fi

log_message "INFO" "脚本启动完成。查看日志: $SYNC_LOG_FILE, $CRON_LOG_FILE, $PYTHON_CRAWLER_LOG_FILE"
if [ "$1" != "sync" ]; then
    tail -F "$SYNC_LOG_FILE" "$CRON_LOG_FILE" "$PYTHON_CRAWLER_LOG_FILE" /dev/null
fi
