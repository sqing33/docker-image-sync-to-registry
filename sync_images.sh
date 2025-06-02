#!/bin/sh

# sync_images.sh
# 这个脚本用于同步 Docker Hub 镜像到本地私有仓库
# 它会定期从 Docker Hub 拉取镜像并推送到本地仓库

# 添加日志函数
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $message" >> "$SYNC_LOG_FILE" # 确保所有日志都进入主同步日志
    echo "$timestamp - $message" # 同时输出到标准输出，方便查看容器日志
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
for arch_val; do # 避免使用与外部变量同名的循环变量名
    TARGET_ARCHS="$TARGET_ARCHS $arch_val"
done
IFS="$OLD_IFS"

CRON_LOG_FILE="${LOG_DIR}/cron.log"  # cron任务日志
SYNC_LOG_FILE="${LOG_DIR}/sync_images_activity.log"  # 主同步日志
PYTHON_CRAWLER_LOG_FILE="${LOG_DIR}/docker_hub_crawler_output.log"  # Python脚本的输出日志

# --- 依赖检查和设置 ---
ensure_dependencies() {
    # 提前创建日志文件，确保 log_message 可以立即写入
    mkdir -p "$IMAGE_LIST_DIR" "$LOG_DIR"
    touch "$CRON_LOG_FILE" "$SYNC_LOG_FILE" "$PYTHON_CRAWLER_LOG_FILE"

    if [ -z "$REGISTRY_URL" ]; then
        log_message "错误: 关键环境变量 REGISTRY_URL 未设置。"
        exit 1
    fi
    
    if ! command -v jq > /dev/null; then
        log_message "尝试安装 jq..."
        if ! apk add --no-cache jq > /dev/null 2>&1; then
            log_message "错误: jq 安装失败。请手动安装。"
            exit 1
        else
            log_message "jq 安装成功。"
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
}

log_config() {
    log_message "开始记录配置信息..."
    
    log_message "--- 初始配置信息 ---"
    log_message "Registry URL: $REGISTRY_URL"
    log_message "Cron Schedule: $CRON_SCHEDULE"
    log_message "Sync on Start: $SYNC_ON_START"
    log_message "Target Architecture(s): $TARGET_ARCH" # 显示原始的 TARGET_ARCH
    log_message "Processed Target Architectures: $TARGET_ARCHS" # 显示处理后的 TARGET_ARCHS
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
# 参数1: 完整的镜像名称 (例如 docker.io/library/nginx:latest 或 myregistry/nginx:latest)
# 参数2: 目标架构 (例如 linux/amd64)
get_arch_image_config_digest() {
    local full_image_name="$1"
    local target_arch="$2"
    local manifest_json
    local platform_manifest_entry_digest
    local image_config_digest_value=""

    # 尝试获取 manifest list
    manifest_json=$(docker manifest inspect "$full_image_name" 2>/dev/null)

    if [ -z "$manifest_json" ]; then
        # 如果获取 manifest list 失败，可能它是一个单架构镜像，或者镜像不存在
        # 尝试直接将其视为单架构镜像获取 config digest
        # 注意: docker inspect 默认会拉取镜像（如果本地不存在且是远程镜像名）
        # 但我们期望的是检查远程仓库，所以 manifest inspect 是首选
        # 如果 full_image_name 是远程的，这里可能还是会失败或信息不准确
        # 理想情况下，应该先确保镜像是针对特定平台的
        # log_message "调试: '$full_image_name' 不是 manifest list，尝试作为单架构镜像处理。"
        image_config_digest_value=$(docker inspect --type=image "$full_image_name" 2>/dev/null | jq -r '.[0].Config.Digest // ""' 2>/dev/null)
        if [ -z "$image_config_digest_value" ] || [ "$image_config_digest_value" == "null" ] || [ "$image_config_digest_value" == '""' ]; then
            # log_message "调试: 无法从 docker inspect 获取 '$full_image_name' 的 config digest。"
            image_config_digest_value=""
        fi
        echo "$image_config_digest_value"
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
            # 从 full_image_name 中提取基础名称，不包含 tag 或 digest
            if echo "$full_image_name" | grep -q '@sha256:'; then # 如果是按 digest 引用
                 image_name_base=$(echo "$full_image_name" | cut -d@ -f1)
            else # 如果是按 tag 引用
                 image_name_base=$(echo "$full_image_name" | cut -d: -f1)
            fi
            
            # 检查特定平台的 manifest
            local specific_image_manifest_json
            specific_image_manifest_json=$(docker manifest inspect "${image_name_base}@${platform_manifest_entry_digest}" 2>/dev/null)
            
            if [ -n "$specific_image_manifest_json" ]; then
                image_config_digest_value=$(echo "$specific_image_manifest_json" | jq -r '.config.digest // ""' 2>/dev/null)
            fi
        fi
    else
        # 不是 manifest list，直接获取 config digest (这部分逻辑可能与上面 if [ -z "$manifest_json" ] 重复，但多一层保障)
        image_config_digest_value=$(echo "$manifest_json" | jq -r '.config.digest // ""' 2>/dev/null)
    fi
    
    if [ -z "$image_config_digest_value" ] || [ "$image_config_digest_value" == "null" ] || [ "$image_config_digest_value" == '""' ]; then
        image_config_digest_value="" 
    fi
    
    echo "$image_config_digest_value"
}

# 同步函数
sync_images() {
    log_message "开始执行镜像同步"
    
    mkdir -p "$IMAGE_LIST_DIR"
    
    local LATEST_FILE
    if [ -f "$CUSTOM_IMAGES_FILE" ]; then
        log_message "使用自定义镜像列表文件: $CUSTOM_IMAGES_FILE"
        LATEST_FILE="$CUSTOM_IMAGES_FILE"
    else
        log_message "未找到自定义镜像列表文件，将使用爬虫获取镜像列表"
        # Python 脚本的输出应该直接写入 $PYTHON_CRAWLER_LOG_FILE
        # 脚本执行的日志(stdout/stderr)也重定向到该文件
        log_message "执行 Python 爬虫脚本: $PYTHON_SCRIPT_PATH (输出到 $PYTHON_CRAWLER_LOG_FILE)"
        if ! python3 "$PYTHON_SCRIPT_PATH" > "$PYTHON_CRAWLER_LOG_FILE" 2>&1; then
            log_message "错误: Python 脚本执行失败。详情请查看 $PYTHON_CRAWLER_LOG_FILE"
            return 1
        fi
        log_message "Python 脚本执行完成。"

        LATEST_FILE=$(ls -t "${IMAGE_LIST_DIR}/docker_images_"*.txt 2>/dev/null | head -n1)
        
        if [ -z "$LATEST_FILE" ] || [ ! -f "$LATEST_FILE" ]; then
            log_message "错误: 未找到有效的镜像列表文件 (期望在 $IMAGE_LIST_DIR 下找到 docker_images_*.txt)。"
            return 1
        fi
        log_message "使用爬虫生成的镜像列表文件: $LATEST_FILE"
    fi
    
    # 使用 cat 和 while read 循环，确保最后一行也能处理
    # 并且在循环外定义临时目录的 trap，确保即使循环中出错也能清理
    local current_temp_dir
    current_temp_dir=$(mktemp -d)
    # shellcheck disable=SC2064 # current_temp_dir 在 trap 执行时会被正确捕获
    trap 'log_message "清理临时目录: $current_temp_dir"; rm -rf "$current_temp_dir"' EXIT INT TERM

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
        
        local hub_image_name_ns
        local image_name_for_local_repo
        local is_official_image
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
        
        local hub_image_full="docker.io/${hub_image_name_ns}:${image_tag}"
        local local_image_full="${REGISTRY_URL}/${actual_local_repo_path}:${image_tag}"

        log_message "处理镜像: $hub_image_full -> $local_image_full"

        # 为当前处理的镜像创建特定的临时文件
        local archs_to_sync_file="$current_temp_dir/archs_to_sync_${image_name_part//\//_}_${image_tag}.txt"
        local arch_images_for_manifest_file="$current_temp_dir/arch_images_for_manifest_${image_name_part//\//_}_${image_tag}.txt"
        >"$archs_to_sync_file" # 创建或清空文件
        >"$arch_images_for_manifest_file"

        local needs_sync_overall=false
        for target_arch_loop in $TARGET_ARCHS; do # 使用不同的循环变量名
            log_message "检查架构 $target_arch_loop for $hub_image_full..."
            hub_config_digest=$(get_arch_image_config_digest "$hub_image_full" "$target_arch_loop")
            if [ -z "$hub_config_digest" ]; then
                log_message "警告: 无法获取 Docker Hub 镜像 $hub_image_full 的 $target_arch_loop Config Digest. 可能该架构不存在或访问受限. 跳过此架构..."
                continue
            fi
            
            local_config_digest=$(get_arch_image_config_digest "$local_image_full" "$target_arch_loop")
            if [ "$hub_config_digest" == "$local_config_digest" ]; then
                log_message "本地镜像 $local_image_full ($target_arch_loop) 与 Docker Hub 版本 (Digest: $hub_config_digest) 一致。跳过同步此架构。"
                continue
            else
                log_message "本地镜像 $local_image_full ($target_arch_loop) 与 Docker Hub (Digest: $hub_config_digest vs Local: $local_config_digest) 不同或本地不存在。计划同步。"
                echo "$target_arch_loop" >> "$archs_to_sync_file"
                needs_sync_overall=true
            fi
        done

        if [ "$needs_sync_overall" = "false" ]; then
            log_message "镜像 $hub_image_full 所有目标架构均已是最新版本或无需更新。跳过。"
            continue # 处理下一个镜像
        fi
        
        arch_count=$(wc -l < "$archs_to_sync_file")
        if [ "$arch_count" -eq 0 ]; then # 双重检查，理论上 needs_sync_overall=false 时会跳过
             log_message "没有架构需要为 $hub_image_full 同步。"
             continue
        fi
        log_message "开始同步 $hub_image_full 的 $arch_count 个架构..."

        # 拉取、标记并推送所有需要同步的架构的镜像
        while IFS= read -r current_target_arch_sync; do # 使用不同的循环变量名
            log_message "拉取 $hub_image_full (架构: $current_target_arch_sync)..."
            
            # 拉取原始镜像时，不指定平台，让docker自行处理，或者如果pull支持--platform，则使用它
            # Docker pull 会将拉取的镜像存储在本地，并根据其 manifest 确定其原始名称和标签
            if ! docker pull --platform "$current_target_arch_sync" "$hub_image_full"; then
                log_message "错误: 拉取 $hub_image_full (架构: $current_target_arch_sync) 失败。"
                continue # 处理下一个需要同步的架构
            fi
            
            # 为每个架构创建一个带有特定后缀的本地标记，这个标记将包含私有仓库地址
            # 例如：myregistry.com/library/nginx:latest-linux-amd64
            local_image_arch_tagged="${local_image_full}-${current_target_arch_sync//\//-}" # 替换 / 为 -
            
            log_message "标记 $hub_image_full 为 $local_image_arch_tagged"
            # 注意：此时 $hub_image_full 在本地可能已经指向了特定平台的镜像
            if ! docker tag "$hub_image_full" "$local_image_arch_tagged"; then
                log_message "错误: 标记 $hub_image_full 为 $local_image_arch_tagged 失败。"
                # 清理刚为特定平台拉取的 $hub_image_full，如果它是特定平台的版本
                # docker rmi "$hub_image_full" 2>/dev/null || true
                continue
            fi

            log_message "推送带架构的镜像 $local_image_arch_tagged 到私有仓库..."
            if ! docker push "$local_image_arch_tagged"; then
                log_message "错误: 推送带架构的镜像 $local_image_arch_tagged 失败。"
                docker rmi "$local_image_arch_tagged" 2>/dev/null || true # 清理本地标记失败的镜像
                # 清理刚为特定平台拉取的 $hub_image_full
                # docker rmi "$hub_image_full" 2>/dev/null || true
                continue
            fi
            
            # 成功推送到仓库后，才将其加入到 manifest 列表
            echo "$local_image_arch_tagged" >> "$arch_images_for_manifest_file"

            # 清理原始的、特定平台的 $hub_image_full (例如 docker.io/library/nginx:latest)
            # 因为我们已经将其标记并推送为带架构后缀的版本
            log_message "清理本地的 $hub_image_full (在拉取 $current_target_arch_sync 后)"
            docker rmi "$hub_image_full" 2>/dev/null || true

        done < "$archs_to_sync_file"

        # 创建多架构 manifest，仅当有成功推送到仓库的架构镜像时
        if [ -s "$arch_images_for_manifest_file" ]; then
            log_message "准备为 $local_image_full 创建多架构 manifest..."
            
            MANIFEST_IMAGES_ARGS=$(cat "$arch_images_for_manifest_file" | tr '\n' ' ')
            log_message "使用以下已推送的架构镜像创建 manifest: $MANIFEST_IMAGES_ARGS"

            # 先尝试移除已存在的同名 manifest list，避免 'manifest already exists' 错误
            # 这在更新 manifest 时是必要的
            log_message "尝试移除已存在的旧 manifest list: $local_image_full (如果存在)"
            docker manifest rm "$local_image_full" 2>/dev/null || true 

            if ! docker manifest create "$local_image_full" $MANIFEST_IMAGES_ARGS; then
                log_message "错误: 创建 manifest $local_image_full 失败。引用的镜像: $MANIFEST_IMAGES_ARGS"
            else
                log_message "成功创建本地 manifest list: $local_image_full。现在开始推送..."
                # 为 manifest list 中的每个镜像添加注释（可选，但推荐）
                # for image_in_manifest in $MANIFEST_IMAGES_ARGS; do
                #     arch_from_tag=$(echo "$image_in_manifest" | rev | cut -d- -f1,2 | rev) #  例如 linux-amd64
                #     os_arch=$(echo "$arch_from_tag" | sed 's/-/ \//') # linux/amd64
                #     docker manifest annotate "$local_image_full" "$image_in_manifest" --os "$(echo $os_arch | cut -d' ' -f1)" --arch "$(echo $os_arch | cut -d' ' -f2)"
                # done

                if ! docker manifest push "$local_image_full"; then
                    log_message "错误: 推送 manifest $local_image_full 失败。"
                    # 如果推送失败，本地创建的 manifest list 也应该被清理
                    docker manifest rm "$local_image_full" 2>/dev/null || true 
                else
                    log_message "成功创建并推送多架构 manifest: $local_image_full"
                fi
            fi
        elif [ "$arch_count" -gt 0 ]; then 
             log_message "警告: $hub_image_full 的所有待同步架构均未能成功推送到仓库，无法创建 manifest。"
        fi

        # 清理本地标记的、带架构后缀的镜像 (例如 myregistry/nginx:latest-linux-amd64)
        # 这些镜像的内容已经推送到私有仓库，并且被 manifest list (如果成功创建并推送) 引用。
        # 本地的这些tag可以安全移除。
        log_message "清理为 $local_image_full 创建的本地带架构后缀的镜像..."
        if [ -f "$arch_images_for_manifest_file" ]; then
            while IFS= read -r arch_image_to_remove; do
                log_message "移除本地镜像: $arch_image_to_remove"
                docker rmi "$arch_image_to_remove" 2>/dev/null || true
            done < "$arch_images_for_manifest_file"
        fi
        
        # 清理为当前镜像创建的临时文件 (不是整个目录，目录由trap清理)
        rm -f "$archs_to_sync_file" "$arch_images_for_manifest_file"

    done < "$LATEST_FILE" # 主循环结束
    
    # trap 会在脚本结束时自动清理 current_temp_dir
    # 如果需要手动立即清理，可以取消注释下一行，但通常 trap 更好
    # rm -rf "$current_temp_dir" 
    # trap - EXIT INT TERM # 移除 trap

    log_message "镜像同步执行完毕"
}

# --- 主逻辑 ---
ensure_dependencies # 首先确保依赖和日志文件已就绪
log_config

# 如果是手动执行同步命令
if [ "$1" = "sync" ]; then
    sync_images
    exit 0
fi

# 如果是容器启动时的首次运行
if [ "$SYNC_ON_START" = "true" ]; then
    log_message "SYNC_ON_START 为 true，执行首次同步..."
    sync_images
    log_message "首次同步执行完毕。"
fi

# 设置cron任务
if command -v crond > /dev/null; then
    log_message "设置 cron 任务: '$CRON_SCHEDULE /app/sync_images.sh sync >> $SYNC_LOG_FILE 2>&1'"
    # 清空现有的cron配置
    echo "" > /etc/crontabs/root
    
    # 添加新的cron任务，并确保其标准输出和错误也重定向到主同步日志
    echo "$CRON_SCHEDULE /app/sync_images.sh sync >> $SYNC_LOG_FILE 2>&1" >> /etc/crontabs/root
    
    # 启动cron服务
    log_message "启动 crond 服务..."
    crond -f -l 8 -L "$CRON_LOG_FILE" & # cron 自身的日志输出到 CRON_LOG_FILE
else
    log_message "警告: crond 未找到，无法设置定时任务。"
fi

log_message "脚本启动完成。如果 crond 已启动，将按计划执行同步。"
log_message "使用 'docker logs <container_name>' 查看实时日志。"
log_message "同步活动日志位于: $SYNC_LOG_FILE"
log_message "Cron守护进程日志位于: $CRON_LOG_FILE"
log_message "Python爬虫输出日志位于: $PYTHON_CRAWLER_LOG_FILE"

# 使用tail监控日志文件，以便 'docker logs' 可以持续输出
# /dev/null 是为了确保 tail 在文件不存在或轮转时不会立即退出
tail -F "$SYNC_LOG_FILE" "$CRON_LOG_FILE" "$PYTHON_CRAWLER_LOG_FILE" /dev/null
