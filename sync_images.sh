#!/bin/sh

# sync_images.sh
# 这个脚本用于同步 Docker Hub 镜像到本地私有仓库
# 它会定期从 Docker Hub 拉取镜像并推送到本地仓库

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

# --- 辅助变量 ---
# 将TARGET_ARCH分割成数组
IFS=',' read -ra TARGET_ARCHS <<< "$TARGET_ARCH"
CRON_LOG_FILE="${LOG_DIR}/cron.log"  # cron任务日志
SYNC_LOG_FILE="${LOG_DIR}/sync_images_activity.log"  # 主同步日志
PYTHON_CRAWLER_LOG_FILE="${LOG_DIR}/docker_hub_crawler_output.log"  # Python脚本的输出日志

# --- 依赖检查和设置 ---
ensure_dependencies() {
    # 检查必要的环境变量和依赖
    if [ -z "$REGISTRY_URL" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误: 关键环境变量 REGISTRY_URL 未设置。" >> "$SYNC_LOG_FILE"
        exit 1
    fi
    if ! command -v jq > /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 信息: jq 未安装，尝试安装..." >> "$SYNC_LOG_FILE"
        if apk add --no-cache jq > /dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 信息: jq 安装成功。" >> "$SYNC_LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误: jq 安装失败。请手动安装。" >> "$SYNC_LOG_FILE"
            exit 1
        fi
    fi
    if ! command -v docker > /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误: docker CLI 未安装或不在PATH中。" >> "$SYNC_LOG_FILE"
        exit 1
    fi
    if [ ! -f "$PYTHON_SCRIPT_PATH" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误: Python 爬虫脚本 '$PYTHON_SCRIPT_PATH' 未找到。" >> "$SYNC_LOG_FILE"
        exit 1
    fi
    mkdir -p "$IMAGE_LIST_DIR" "$LOG_DIR"
    touch "$CRON_LOG_FILE" "$SYNC_LOG_FILE" "$PYTHON_CRAWLER_LOG_FILE"
}

log_config() {
    # 记录当前配置信息
    echo "$(date '+%Y-%m-%d %H:%M:%S') --- 初始配置信息 ---" >> "$SYNC_LOG_FILE"
    echo "Registry URL: $REGISTRY_URL" >> "$SYNC_LOG_FILE"
    echo "Cron Schedule: $CRON_SCHEDULE" >> "$SYNC_LOG_FILE"
    echo "Sync on Start: $SYNC_ON_START" >> "$SYNC_LOG_FILE"
    echo "Target Architecture: $TARGET_ARCH (OS: $TARGET_OS, Arch: $TARGET_ARCHITECTURE)" >> "$SYNC_LOG_FILE"
    echo "Remove 'library/' prefix for local official images: $REMOVE_LIBRARY_PREFIX_ON_LOCAL" >> "$SYNC_LOG_FILE"
    echo "Python Script: $PYTHON_SCRIPT_PATH" >> "$SYNC_LOG_FILE"
    echo "Image List Directory: $IMAGE_LIST_DIR" >> "$SYNC_LOG_FILE"
    echo "Max Pages Per Category to Crawl: $MAX_PAGES_PER_CATEGORY" >> "$SYNC_LOG_FILE"
    echo "Log Files: $CRON_LOG_FILE, $SYNC_LOG_FILE, $PYTHON_CRAWLER_LOG_FILE" >> "$SYNC_LOG_FILE"
    echo "---------------------------" >> "$SYNC_LOG_FILE"
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ================== 开始执行镜像同步 ==================" >> "$SYNC_LOG_FILE"
    
    # 确保输出目录存在
    mkdir -p "$IMAGE_LIST_DIR"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 运行Python脚本获取最新镜像列表 (最多 $MAX_PAGES_PER_CATEGORY 页/分类)..." >> "$SYNC_LOG_FILE"
    
    # 切换到输出目录
    cd "$IMAGE_LIST_DIR" || {
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误: 无法切换到输出目录 '$IMAGE_LIST_DIR'" >> "$SYNC_LOG_FILE"
        return 1
    }
    
    if ! python3 "$PYTHON_SCRIPT_PATH" 2>&1 >> "$PYTHON_CRAWLER_LOG_FILE" >> "$SYNC_LOG_FILE"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误: Python 脚本 '$PYTHON_SCRIPT_PATH' 执行失败。" >> "$SYNC_LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ================== 镜像同步异常结束 ==================" >> "$SYNC_LOG_FILE"
        return 1
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Python脚本执行完毕。" >> "$SYNC_LOG_FILE"

    # 查找最新的镜像列表文件
    LATEST_FILE=$(ls -t "/app/output/docker_images_"*.txt 2>/dev/null | head -n1)
    
    if [ -z "$LATEST_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误: 未找到由 Python 脚本生成的镜像列表文件。" >> "$SYNC_LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ================== 镜像同步异常结束 ==================" >> "$SYNC_LOG_FILE"
        return 1
    fi
    
    if [ ! -f "$LATEST_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误: 镜像列表文件 '$LATEST_FILE' 不存在。" >> "$SYNC_LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ================== 镜像同步异常结束 ==================" >> "$SYNC_LOG_FILE"
        return 1
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 从文件 $LATEST_FILE 读取镜像列表..." >> "$SYNC_LOG_FILE"
    
    # 使用 cat 和 while read 循环，确保最后一行也能处理
    cat "$LATEST_FILE" | while IFS= read -r image_from_crawler || [ -n "$image_from_crawler" ]; do
        if [ -z "$image_from_crawler" ]; then
            continue
        fi

        echo "" >> "$SYNC_LOG_FILE"
        echo "-------------------------------------------------" >> "$SYNC_LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 处理原始爬取名称: $image_from_crawler" >> "$SYNC_LOG_FILE"

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

        echo "  源镜像 (Docker Hub): $hub_image_full" >> "$SYNC_LOG_FILE"
        echo "  目标镜像 (本地 Registry): $local_image_full" >> "$SYNC_LOG_FILE"

        # 遍历所有目标架构
        for target_arch in "${TARGET_ARCHS[@]}"; do
            echo "  处理架构: $target_arch" >> "$SYNC_LOG_FILE"
            
            # 获取并比较镜像的 Config Digest
            echo "  获取 Docker Hub 镜像 Config Digest (平台: $target_arch)..." >> "$SYNC_LOG_FILE"
            hub_config_digest=$(get_arch_image_config_digest "$hub_image_full" "$target_arch")

            if [ -z "$hub_config_digest" ]; then
                echo "  警告: 无法获取 Docker Hub 镜像 '$hub_image_full' 的 $target_arch Config Digest. 跳过..." >> "$SYNC_LOG_FILE"
                continue
            fi
            echo "    Docker Hub ($target_arch) Config Digest: $hub_config_digest" >> "$SYNC_LOG_FILE"
            
            echo "  获取本地 Registry 镜像 Config Digest (平台: $target_arch)..." >> "$SYNC_LOG_FILE"
            local_config_digest=$(get_arch_image_config_digest "$local_image_full" "$target_arch")
            
            if [ -n "$local_config_digest" ]; then
                echo "    本地 Registry ($target_arch) Config Digest: $local_config_digest" >> "$SYNC_LOG_FILE"
            else
                echo "    本地 Registry 中不存在镜像 '$local_image_full' ($target_arch) 或无法获取其 Config Digest。" >> "$SYNC_LOG_FILE"
            fi

            # 根据 Config Digest 决定是否需要同步
            if [ "$hub_config_digest" == "$local_config_digest" ] && [ -n "$hub_config_digest" ]; then
                echo "  镜像 '$local_image_full' ($target_arch) Config Digest 匹配。已是最新版本。跳过同步。" >> "$SYNC_LOG_FILE"
            else
                echo "  Config Digest ('$hub_config_digest' vs '$local_config_digest') 不匹配或本地不存在。开始同步 '$hub_image_full' (将拉取 $target_arch)..." >> "$SYNC_LOG_FILE"
                
                # 执行镜像同步的三个步骤：拉取、标记、推送
                echo "    1. 拉取: $hub_image_full (指定平台: $target_arch)" >> "$SYNC_LOG_FILE"
                if ! docker pull --platform "$target_arch" "$hub_image_full"; then
                    echo "    错误: 拉取 '$hub_image_full' (平台 $target_arch) 失败。" >> "$SYNC_LOG_FILE"
                    continue
                fi
                
                echo "    2. 标记: $hub_image_full -> $local_image_full" >> "$SYNC_LOG_FILE"
                if ! docker tag "$hub_image_full" "$local_image_full"; then
                    echo "    错误: 标记镜像 '$hub_image_full' 为 '$local_image_full' 失败。" >> "$SYNC_LOG_FILE"
                    docker rmi "$hub_image_full" 2>/dev/null || true 
                    continue
                fi
                
                echo "    3. 推送: $local_image_full" >> "$SYNC_LOG_FILE"
                if ! docker push "$local_image_full"; then
                    echo "    错误: 推送镜像 '$local_image_full' 失败。" >> "$SYNC_LOG_FILE"
                    docker rmi "$local_image_full" 2>/dev/null || true 
                    docker rmi "$hub_image_full" 2>/dev/null || true  
                    continue
                fi
                echo "  成功同步到 '$local_image_full' ($target_arch)" >> "$SYNC_LOG_FILE"
            fi
            
            # 清理本地缓存
            echo "  清理原始拉取的本地缓存: $hub_image_full ..." >> "$SYNC_LOG_FILE"
            docker rmi "$hub_image_full" 2>/dev/null || true 
        done

    done
    echo "-------------------------------------------------" >> "$SYNC_LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ================== 镜像同步执行完毕 ==================" >> "$SYNC_LOG_FILE"
}

# --- 主逻辑 ---
ensure_dependencies
log_config

# 如果是手动执行同步命令
if [ "$1" = "sync" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 手动触发同步任务..." >> "$SYNC_LOG_FILE"
    sync_images
    exit 0
fi

# 如果是容器启动时的首次运行
if [ "$SYNC_ON_START" = "true" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 检测到 SYNC_ON_START=true，执行启动时同步..." >> "$SYNC_LOG_FILE"
    sync_images
fi

# 设置cron任务
if command -v crond > /dev/null; then
    # 清空现有的cron配置
    echo "" > /etc/crontabs/root
    
    # 添加新的cron任务
    echo "$CRON_SCHEDULE /app/sync_images.sh sync >> $SYNC_LOG_FILE 2>&1" >> /etc/crontabs/root
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Cron 任务已设置: $(cat /etc/crontabs/root)" >> "$SYNC_LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 启动 cron 服务..." >> "$SYNC_LOG_FILE"
    
    # 启动cron服务
    crond -f -l 8 -L "$CRON_LOG_FILE" &
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Cron 服务已启动。容器将通过 tail 保持运行。" >> "$SYNC_LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 警告: crond 未找到，无法设置定时任务。" >> "$SYNC_LOG_FILE"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - 容器正在运行，监控日志: $SYNC_LOG_FILE 和 $CRON_LOG_FILE" >> "$SYNC_LOG_FILE"

# 使用tail监控日志文件
tail -F "$SYNC_LOG_FILE" "$CRON_LOG_FILE" /dev/null
