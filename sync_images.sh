#!/bin/sh

# sync_images.sh
# 这个脚本用于同步 Docker Hub 镜像到本地私有仓库
# 它会定期从 Docker Hub 拉取镜像并推送到本地仓库

# 添加日志函数
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $message"
}

# --- 配置部分 ---
REGISTRY_URL="${REGISTRY_URL}"  # 本地私有仓库的URL
CRON_SCHEDULE="${CRON_SCHEDULE:-0 4 * * *}"  # 默认每天凌晨4点执行
SYNC_ON_START="${SYNC_ON_START:-true}"  # 容器启动时是否立即同步
TARGET_ARCH="${TARGET_ARCH:-linux/amd64}"  # 目标架构，支持逗号分隔的多个架构
REMOVE_LIBRARY_PREFIX_ON_LOCAL="${REMOVE_LIBRARY_PREFIX_ON_LOCAL:-true}"  # 是否移除本地镜像的library/前缀
PYTHON_SCRIPT_PATH="/app/docker_hub_crawler.py"  # Python爬虫脚本路径
IMAGE_LIST_DIR="/app/output"  # 镜像列表输出目录
LOG_DIR="/var/log"  # 日志目录
MAX_PAGES_PER_CATEGORY="${MAX_PAGES_PER_CATEGORY:-1}"  # 控制Python脚本爬取的页数
CUSTOM_IMAGES_FILE="/app/custom_images.txt"  # 自定义镜像列表文件路径

# --- 辅助变量 ---
# 将TARGET_ARCH分割成数组
OLD_IFS="$IFS"
IFS=","
set -- $TARGET_ARCH
TARGET_ARCHS=""
for arch; do
    TARGET_ARCHS="$TARGET_ARCHS $arch"
done
IFS="$OLD_IFS"
CRON_LOG_FILE="${LOG_DIR}/cron.log"  # cron任务日志
SYNC_LOG_FILE="${LOG_DIR}/sync_images_activity.log"  # 主同步日志
PYTHON_CRAWLER_LOG_FILE="${LOG_DIR}/docker_hub_crawler_output.log"  # Python脚本的输出日志

# --- 依赖检查和设置 ---
ensure_dependencies() {
    # 检查必要的环境变量和依赖
    if [ -z "$REGISTRY_URL" ]; then
        log_message "错误: 关键环境变量 REGISTRY_URL 未设置。"
        exit 1
    fi
    
    if ! command -v jq > /dev/null; then
        if ! apk add --no-cache jq > /dev/null 2>&1; then
            log_message "错误: jq 安装失败。请手动安装。"
            exit 1
        fi
    fi
    
    if ! command -v docker > /dev/null; then
        log_message "错误: docker CLI 未安装或不在PATH中。"
        exit 1
    fi
    
    if [ ! -f "$PYTHON_SCRIPT_PATH" ]; then
        log_message "错误: Python 爬虫脚本 '$PYTHON_SCRIPT_PATH' 未找到。"
        exit 1
    fi
    
    mkdir -p "$IMAGE_LIST_DIR" "$LOG_DIR"
    touch "$CRON_LOG_FILE" "$SYNC_LOG_FILE" "$PYTHON_CRAWLER_LOG_FILE"
}

log_config() {
    log_message "开始记录配置信息..."
    
    # 记录当前配置信息
    log_message "--- 初始配置信息 ---"
    log_message "Registry URL: $REGISTRY_URL"
    log_message "Cron Schedule: $CRON_SCHEDULE"
    log_message "Sync on Start: $SYNC_ON_START"
    log_message "Target Architecture: $TARGET_ARCH"
    log_message "Remove 'library/' prefix for local official images: $REMOVE_LIBRARY_PREFIX_ON_LOCAL"
    log_message "Python Script: $PYTHON_SCRIPT_PATH"
    log_message "Image List Directory: $IMAGE_LIST_DIR"
    log_message "Max Pages Per Category to Crawl: $MAX_PAGES_PER_CATEGORY"
    log_message "Custom Images File: $CUSTOM_IMAGES_FILE"
    log_message "Log Files: $CRON_LOG_FILE, $SYNC_LOG_FILE, $PYTHON_CRAWLER_LOG_FILE"
    log_message "---------------------------"
    
    log_message "配置信息记录完成"
}

# 函数：获取指定架构的 Image Config Digest
# 参数1: 完整的镜像名称 (例如 docker.io/library/nginx:latest)
# 参数2: 目标架构
get_arch_image_config_digest() {
    local full_image_name="$1"
    local target_arch="$2"
    local manifest_json
    local platform_manifest_entry_digest
    local image_config_digest_value=""

    manifest_json=$(docker manifest inspect "$full_image_name" 2>/dev/null)

    if [ -z "$manifest_json" ]; then
        echo ""
        return
    fi

    # 检查是否是一个 manifest list
    is_manifest_list=$(echo "$manifest_json" | jq 'if type == "array" then false else (.manifests | type == "array" and length > 0) end' 2>/dev/null)

    if [ "$is_manifest_list" = "true" ]; then
        # 从 manifest list 中获取指定平台的 manifest entry digest
        platform_manifest_entry_digest=$(echo "$manifest_json" | jq -r \
            --arg OS_ARG "$(echo "$target_arch" | cut -d/ -f1)" \
            --arg ARCH_ARG "$(echo "$target_arch" | cut -d/ -f2)" \
            '.manifests[]? | select(.platform.os == $OS_ARG and .platform.architecture == $ARCH_ARG) | .digest' 2>/dev/null)

        if [ -n "$platform_manifest_entry_digest" ] && [ "$platform_manifest_entry_digest" != "null" ] && [ "$platform_manifest_entry_digest" != '""' ]; then
            local image_name_base=$(echo "$full_image_name" | cut -d: -f1)
            local specific_image_manifest_json=$(docker manifest inspect "${image_name_base}@${platform_manifest_entry_digest}" 2>/dev/null)
            
            if [ -n "$specific_image_manifest_json" ]; then
                image_config_digest_value=$(echo "$specific_image_manifest_json" | jq -r '.config.digest // ""' 2>/dev/null)
                if [ -z "$image_config_digest_value" ] || [ "$image_config_digest_value" == "null" ] || [ "$image_config_digest_value" == '""' ]; then
                    image_config_digest_value="" 
                fi
            fi
        fi
    else
        # 如果不是 manifest list，直接获取 config digest
        image_config_digest_value=$(echo "$manifest_json" | jq -r '.config.digest // ""' 2>/dev/null)
        if [ -z "$image_config_digest_value" ] || [ "$image_config_digest_value" == "null" ] || [ "$image_config_digest_value" == '""' ]; then
            image_config_digest_value="" 
        fi
    fi
    
    echo "$image_config_digest_value"
}

# 同步函数
sync_images() {
    log_message "开始执行镜像同步"
    
    # 确保输出目录存在
    mkdir -p "$IMAGE_LIST_DIR"
    
    # 检查是否存在自定义镜像列表文件
    if [ -f "$CUSTOM_IMAGES_FILE" ]; then
        log_message "使用自定义镜像列表文件: $CUSTOM_IMAGES_FILE"
        LATEST_FILE="$CUSTOM_IMAGES_FILE"
    else
        log_message "未找到自定义镜像列表文件，将使用爬虫获取镜像列表"
        
        # 切换到输出目录
        cd "$IMAGE_LIST_DIR" || {
            log_message "错误: 无法切换到输出目录 '$IMAGE_LIST_DIR'"
            return 1
        }
        
        if ! python3 "$PYTHON_SCRIPT_PATH" 2>&1; then
            log_message "错误: Python 脚本执行失败。"
            return 1
        fi

        # 查找最新的镜像列表文件
        LATEST_FILE=$(ls -t "/app/output/docker_images_"*.txt 2>/dev/null | head -n1)
        
        if [ -z "$LATEST_FILE" ] || [ ! -f "$LATEST_FILE" ]; then
            log_message "错误: 未找到有效的镜像列表文件。"
            return 1
        fi
    fi
    
    # 使用 cat 和 while read 循环，确保最后一行也能处理
    cat "$LATEST_FILE" | while IFS= read -r image_from_crawler || [ -n "$image_from_crawler" ]; do
        if [ -z "$image_from_crawler" ]; then
            continue
        fi

        # 解析镜像名称和标签
        image_name_part=$(echo "$image_from_crawler" | cut -d: -f1)
        image_tag_part=$(echo "$image_from_crawler" | cut -d: -f2)

        if [ "$image_name_part" == "$image_tag_part" ] || [ -z "$image_tag_part" ]; then 
            image_tag="latest"
        else
            image_tag="$image_tag_part"
        fi
        
        # 处理官方镜像和用户镜像的命名
        if ! echo "$image_name_part" | grep -q /; then
            hub_image_name_ns="library/${image_name_part}"
            image_name_for_local_repo="$image_name_part"
            is_official_image=true
        else
            hub_image_name_ns="$image_name_part"
            image_name_for_local_repo="$image_name_part"
            is_official_image=false
        fi

        # 确定本地仓库中的镜像路径
        if [ "$is_official_image" = true ] && [ "$REMOVE_LIBRARY_PREFIX_ON_LOCAL" = "true" ]; then
            actual_local_repo_path="$image_name_for_local_repo"
        else
            actual_local_repo_path="$hub_image_name_ns"
        fi
        
        hub_image_full="docker.io/${hub_image_name_ns}:${image_tag}"
        local_image_full="${REGISTRY_URL}/${actual_local_repo_path}:${image_tag}"

        log_message "处理镜像: $hub_image_full"

        # 创建一个临时目录来存储不同架构的镜像
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT

        # 创建一个临时文件来存储需要同步的架构
        archs_to_sync_file="$temp_dir/archs_to_sync.txt"
        touch "$archs_to_sync_file"

        # 遍历所有目标架构，检查是否需要同步
        for target_arch in $TARGET_ARCHS; do
            # 获取并比较镜像的 Config Digest
            hub_config_digest=$(get_arch_image_config_digest "$hub_image_full" "$target_arch")

            if [ -z "$hub_config_digest" ]; then
                log_message "警告: 无法获取 $hub_image_full 的 $target_arch Config Digest. 跳过..."
                continue
            fi
            
            local_config_digest=$(get_arch_image_config_digest "$local_image_full" "$target_arch")

            # 根据 Config Digest 决定是否需要同步
            if [ "$hub_config_digest" == "$local_config_digest" ] && [ -n "$hub_config_digest" ]; then
                log_message "镜像 $local_image_full ($target_arch) 已是最新版本。跳过同步。"
                continue
            fi

            # 将需要同步的架构添加到文件
            echo "$target_arch" >> "$archs_to_sync_file"
        done

        # 如果有需要同步的架构
        if [ -s "$archs_to_sync_file" ]; then
            arch_count=$(wc -l < "$archs_to_sync_file")
            log_message "开始同步 $hub_image_full 的 $arch_count 个架构..."

            # 先拉取、标记和推送所有架构的镜像
            while read -r target_arch; do
                log_message "拉取 $hub_image_full ($target_arch)..."
                
                if ! docker pull --platform "$target_arch" "$hub_image_full"; then
                    log_message "错误: 拉取失败。"
                    continue
                fi
                
                if ! docker tag "$hub_image_full" "$local_image_full"; then
                    log_message "错误: 标记失败。"
                    docker rmi "$hub_image_full" 2>/dev/null || true 
                    continue
                fi

                # 推送镜像到本地仓库
                if ! docker push "$local_image_full"; then
                    log_message "错误: 推送失败。"
                    docker rmi "$local_image_full" 2>/dev/null || true 
                    docker rmi "$hub_image_full" 2>/dev/null || true 
                    continue
                fi

                # 保存本地镜像信息
                echo "$local_image_full" >> "$temp_dir/arch_images.txt"
            done < "$archs_to_sync_file"

            # 创建多架构 manifest
            if [ -f "$temp_dir/arch_images.txt" ]; then
                log_message "创建多架构 manifest: $local_image_full"
                
                # 创建 manifest
                if ! docker manifest create "$local_image_full" $(cat "$temp_dir/arch_images.txt"); then
                    log_message "错误: 创建 manifest 失败。"
                    continue
                fi
                
                # 推送 manifest
                if ! docker manifest push "$local_image_full"; then
                    log_message "错误: 推送 manifest 失败。"
                    docker manifest rm "$local_image_full" 2>/dev/null || true
                    continue
                fi
                
                log_message "成功创建并推送多架构 manifest: $local_image_full"
            fi

            # 最后清理所有本地缓存
            log_message "清理本地缓存..."
            docker rmi "$hub_image_full" 2>/dev/null || true 
            docker rmi "$local_image_full" 2>/dev/null || true
        fi
    done
    log_message "镜像同步执行完毕"
}

# --- 主逻辑 ---
ensure_dependencies
log_config

# 如果是手动执行同步命令
if [ "$1" = "sync" ]; then
    sync_images
    exit 0
fi

# 如果是容器启动时的首次运行
if [ "$SYNC_ON_START" = "true" ]; then
    sync_images
fi

# 设置cron任务
if command -v crond > /dev/null; then
    # 清空现有的cron配置
    echo "" > /etc/crontabs/root
    
    # 添加新的cron任务
    echo "$CRON_SCHEDULE /app/sync_images.sh sync" >> /etc/crontabs/root
    
    # 启动cron服务
    crond -f -l 8 -L "$CRON_LOG_FILE" &
else
    log_message "警告: crond 未找到，无法设置定时任务。"
fi

# 使用tail监控日志文件
tail -F "$SYNC_LOG_FILE" "$CRON_LOG_FILE" /dev/null
