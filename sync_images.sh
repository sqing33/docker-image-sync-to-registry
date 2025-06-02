#!/bin/sh

# sync_images.sh
# 这个脚本用于同步 Docker Hub 镜像到本地私有仓库
# 它会定期从 Docker Hub 拉取镜像并推送到本地仓库

# 添加日志函数
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $message" >> "$SYNC_LOG_FILE"
    echo "$timestamp - $message"
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
MAX_PAGES_PER_CATEGORY="${MAX_PAGES_PER_CATEGORY:-1}" # 确保Python脚本使用此变量
CUSTOM_IMAGES_FILE="/app/custom_images.txt"

# --- 辅助变量 ---
OLD_IFS="$IFS"
IFS=","
set -- $TARGET_ARCH
TARGET_ARCHS=""
for arch_val; do
    TARGET_ARCHS="$TARGET_ARCHS $arch_val"
done
IFS="$OLD_IFS"
TARGET_ARCHS=$(echo "$TARGET_ARCHS" | xargs) # Trim leading/trailing whitespace

CRON_LOG_FILE="${LOG_DIR}/cron.log"
SYNC_LOG_FILE="${LOG_DIR}/sync_images_activity.log"
PYTHON_CRAWLER_LOG_FILE="${LOG_DIR}/docker_hub_crawler_output.log"

# --- 依赖检查和设置 ---
ensure_dependencies() {
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
    log_message "Target Architecture(s) from env: $TARGET_ARCH"
    log_message "Processed Target Architectures: '$TARGET_ARCHS'"
    log_message "Remove 'library/' prefix for local official images: $REMOVE_LIBRARY_PREFIX_ON_LOCAL"
    log_message "Python Script: $PYTHON_SCRIPT_PATH"
    log_message "Image List Directory: $IMAGE_LIST_DIR"
    log_message "Max Pages Per Category to Crawl: $MAX_PAGES_PER_CATEGORY"
    log_message "Custom Images File: $CUSTOM_IMAGES_FILE"
    log_message "Log Files: $CRON_LOG_FILE, $SYNC_LOG_FILE, $PYTHON_CRAWLER_LOG_FILE"
    log_message "---------------------------"
    log_message "配置信息记录完成"
}

get_arch_image_config_digest() {
    local full_image_name="$1"
    local target_arch="$2"
    local manifest_json
    local platform_manifest_entry_digest
    local image_config_digest_value=""

    # log_message "DEBUG: get_arch_image_config_digest for '$full_image_name', arch '$target_arch'"
    manifest_json=$(docker manifest inspect "$full_image_name" 2>/dev/null)

    if [ -z "$manifest_json" ]; then
        # log_message "DEBUG: docker manifest inspect '$full_image_name' returned empty."
        echo ""
        return
    fi

    is_manifest_list=$(echo "$manifest_json" | jq 'if type == "array" then false else (.manifests | type == "array" and length > 0) end' 2>/dev/null)

    if [ "$is_manifest_list" = "true" ]; then
        # log_message "DEBUG: '$full_image_name' is a manifest list. Looking for arch '$target_arch'."
        # log_message "DEBUG: Manifest list for $full_image_name: $(echo "$manifest_json" | jq -c .)"
        platform_manifest_entry_digest=$(echo "$manifest_json" | jq -r \
            --arg OS_ARG "$(echo "$target_arch" | cut -d/ -f1)" \
            --arg ARCH_ARG "$(echo "$target_arch" | cut -d/ -f2)" \
            '.manifests[]? | select(.platform.os == $OS_ARG and .platform.architecture == $ARCH_ARG) | .digest' 2>/dev/null)

        if [ -n "$platform_manifest_entry_digest" ] && [ "$platform_manifest_entry_digest" != "null" ] && [ "$platform_manifest_entry_digest" != '""' ]; then
            # log_message "DEBUG: Found platform manifest entry digest '$platform_manifest_entry_digest' for '$target_arch' in '$full_image_name'."
            local image_name_base
            if echo "$full_image_name" | grep -q '@sha256:'; then
                 image_name_base=$(echo "$full_image_name" | cut -d@ -f1)
            else
                 image_name_base=$(echo "$full_image_name" | cut -d: -f1)
            fi
            
            local specific_image_manifest_json
            # log_message "DEBUG: Inspecting specific platform manifest: '${image_name_base}@${platform_manifest_entry_digest}'"
            specific_image_manifest_json=$(docker manifest inspect "${image_name_base}@${platform_manifest_entry_digest}" 2>/dev/null)
            
            if [ -n "$specific_image_manifest_json" ]; then
                # log_message "DEBUG: Specific platform manifest JSON: $(echo "$specific_image_manifest_json" | jq -c .)"
                image_config_digest_value=$(echo "$specific_image_manifest_json" | jq -r '.config.digest // ""' 2>/dev/null)
            # else
                # log_message "DEBUG: Failed to inspect specific platform manifest ${image_name_base}@${platform_manifest_entry_digest}"
            fi
        # else
            # log_message "DEBUG: No manifest entry found for arch '$target_arch' in '$full_image_name'."
            # log_message "DEBUG: Available platforms in manifest list for '$full_image_name': $(echo "$manifest_json" | jq -c '[.manifests[]?.platform]')"
        fi
    else # Not a manifest list, or jq failed to parse it as such. Treat as a single manifest.
        # log_message "DEBUG: '$full_image_name' is not a manifest list (or jq failed). Assuming single manifest. JSON: $(echo "$manifest_json" | jq -c .)"
        local manifest_os=$(echo "$manifest_json" | jq -r '.platform.os // host_os_from_config_if_available_else_empty' 2>/dev/null) # Placeholder for better extraction
        local manifest_architecture=$(echo "$manifest_json" | jq -r '.platform.architecture // host_arch_from_config_if_available_else_empty' 2>/dev/null) # Placeholder
        
        # For a single manifest, we should ideally check if its platform matches target_arch.
        # However, `docker manifest inspect <image>:<tag>` on a multi-arch tag might return a manifest for *some* platform,
        # not necessarily the host's or the one we want without pulling.
        # This part is complex. If the manifest JSON directly contains os/arch at the top level (as per OCI spec for image manifest), use it.
        # If not, this function might not be able to determine the config digest for a *specific* arch from a *single* manifest
        # unless that manifest is already for the target arch.
        
        # Let's assume if it's not a list, we extract .config.digest if the platform matches
        local actual_os=$(echo "$manifest_json" | jq -r '.platform.os // ""')
        local actual_arch=$(echo "$manifest_json" | jq -r '.platform.architecture // ""')
        local target_os_val=$(echo "$target_arch" | cut -d/ -f1)
        local target_arch_val=$(echo "$target_arch" | cut -d/ -f2)

        if [ "$actual_os" = "$target_os_val" ] && [ "$actual_arch" = "$target_arch_val" ]; then
            image_config_digest_value=$(echo "$manifest_json" | jq -r '.config.digest // ""' 2>/dev/null)
        # else
            # log_message "DEBUG: Single manifest platform '$actual_os/$actual_arch' does not match target '$target_arch'. No digest."
        fi
    fi
    
    if [ -z "$image_config_digest_value" ] || [ "$image_config_digest_value" == "null" ] || [ "$image_config_digest_value" == '""' ]; then
        image_config_digest_value="" 
    fi
    # log_message "DEBUG: Final image_config_digest_value for '$full_image_name', '$target_arch': '$image_config_digest_value'"
    echo "$image_config_digest_value"
}

sync_images() {
    log_message "开始执行镜像同步"
    mkdir -p "$IMAGE_LIST_DIR"
    
    local LATEST_FILE
    if [ -f "$CUSTOM_IMAGES_FILE" ]; then
        log_message "使用自定义镜像列表文件: $CUSTOM_IMAGES_FILE"
        LATEST_FILE="$CUSTOM_IMAGES_FILE"
    else
        log_message "未找到自定义镜像列表文件，将使用爬虫获取镜像列表"
        log_message "执行 Python 爬虫脚本: $PYTHON_SCRIPT_PATH (MAX_PAGES_PER_CATEGORY=$MAX_PAGES_PER_CATEGORY)"
        # Pass MAX_PAGES_PER_CATEGORY to the python script if it accepts it as an env var or arg
        # For now, assuming it reads the env var
        if ! MAX_PAGES_PER_CATEGORY="$MAX_PAGES_PER_CATEGORY" python3 "$PYTHON_SCRIPT_PATH" > "$PYTHON_CRAWLER_LOG_FILE" 2>&1; then
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
    
    local current_temp_dir
    current_temp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap 'log_message "清理临时目录: $current_temp_dir"; rm -rf "$current_temp_dir"; trap - EXIT INT TERM' EXIT INT TERM

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
        
        local hub_image_full="docker.io/${hub_image_name_ns}:${image_tag}"
        local local_image_full="${REGISTRY_URL}/${actual_local_repo_path}:${image_tag}"

        log_message "处理镜像: $hub_image_full -> $local_image_full"

        local archs_to_sync_file="$current_temp_dir/archs_to_sync_${image_name_part//\//_}_${image_tag}.txt"
        local arch_images_for_manifest_file="$current_temp_dir/arch_images_for_manifest_${image_name_part//\//_}_${image_tag}.txt"
        >"$archs_to_sync_file"; >"$arch_images_for_manifest_file"

        local needs_sync_overall=false
        for target_arch_loop in $TARGET_ARCHS; do
            log_message "检查架构 $target_arch_loop for $hub_image_full..."
            hub_config_digest=$(get_arch_image_config_digest "$hub_image_full" "$target_arch_loop")
            if [ -z "$hub_config_digest" ]; then
                log_message "警告: 无法获取 Docker Hub 镜像 $hub_image_full 的 $target_arch_loop Config Digest. 可能该架构不存在、访问受限或非 manifest list。跳过此架构..."
                continue
            fi
            
            local_config_digest=$(get_arch_image_config_digest "$local_image_full" "$target_arch_loop")
            if [ "$hub_config_digest" == "$local_config_digest" ]; then
                log_message "本地镜像 $local_image_full ($target_arch_loop) 与 Docker Hub 版本 (Digest: $hub_config_digest) 一致。跳过同步此架构。"
            else
                log_message "本地镜像 $local_image_full ($target_arch_loop) (Digest: $local_config_digest) 与 Docker Hub (Digest: $hub_config_digest) 不同或本地不存在。计划同步。"
                echo "$target_arch_loop" >> "$archs_to_sync_file"
                needs_sync_overall=true
            fi
        done

        if [ "$needs_sync_overall" = "false" ]; then
            log_message "镜像 $hub_image_full 所有目标架构均已是最新版本或无需更新。跳过。"
            continue
        fi
        
        arch_count=$(wc -l < "$archs_to_sync_file" | xargs)
        if [ "$arch_count" -eq 0 ]; then
             log_message "没有架构需要为 $hub_image_full 同步 (arch_count is 0)。"
             continue
        fi
        log_message "开始同步 $hub_image_full 的 $arch_count 个架构..."

        local any_arch_pushed_successfully=false
        while IFS= read -r current_target_arch_sync; do
            log_message "处理待同步架构: $current_target_arch_sync for $hub_image_full"
            
            log_message "拉取 $hub_image_full (架构: $current_target_arch_sync)..."
            if ! docker pull --platform "$current_target_arch_sync" "$hub_image_full"; then
                log_message "错误: 拉取 $hub_image_full (架构: $current_target_arch_sync) 失败。"
                continue
            fi
            
            local local_image_arch_tagged="${local_image_full}-${current_target_arch_sync//\//-}"
            
            log_message "标记 $hub_image_full 为 $local_image_arch_tagged"
            if ! docker tag "$hub_image_full" "$local_image_arch_tagged"; then
                log_message "错误: 标记 $hub_image_full 为 $local_image_arch_tagged 失败。"
                log_message "清理本地 $hub_image_full (因标记失败)"
                docker rmi "$hub_image_full" 2>/dev/null || true 
                continue
            fi

            log_message "推送带架构的镜像 $local_image_arch_tagged 到私有仓库..."
            if ! docker push "$local_image_arch_tagged"; then
                log_message "错误: 推送带架构的镜像 $local_image_arch_tagged 失败。"
                log_message "清理本地标记的（但推送失败的）镜像: $local_image_arch_tagged"
                docker rmi "$local_image_arch_tagged" 2>/dev/null || true 
                log_message "清理本地 $hub_image_full (因 $local_image_arch_tagged 推送失败)"
                docker rmi "$hub_image_full" 2>/dev/null || true
                continue
            fi
            
            log_message "成功推送 $local_image_arch_tagged. 将其添加到 manifest 创建列表。"
            echo "$local_image_arch_tagged" >> "$arch_images_for_manifest_file"
            any_arch_pushed_successfully=true

            log_message "清理本地的 $hub_image_full (在成功拉取、标记并推送 $current_target_arch_sync 后)"
            docker rmi "$hub_image_full" 2>/dev/null || true
        done < "$archs_to_sync_file"

        if [ "$any_arch_pushed_successfully" = true ] && [ -s "$arch_images_for_manifest_file" ]; then
            log_message "准备为 $local_image_full 创建多架构 manifest..."
            MANIFEST_IMAGES_ARGS=$(cat "$arch_images_for_manifest_file" | xargs) # xargs to put them on one line
            log_message "使用以下已推送的架构镜像创建 manifest: $MANIFEST_IMAGES_ARGS"

            log_message "尝试移除已存在的旧 manifest list: $local_image_full (如果存在)"
            docker manifest rm "$local_image_full" 2>/dev/null || true 

            if ! docker manifest create "$local_image_full" $MANIFEST_IMAGES_ARGS; then
                log_message "错误: 创建 manifest $local_image_full 失败。引用的镜像: $MANIFEST_IMAGES_ARGS"
            else
                log_message "成功创建本地 manifest list: $local_image_full。现在开始推送..."
                # Annotate manifest (optional but good practice)
                # Ensure arch_images_for_manifest_file contains one image per line
                while IFS= read -r image_in_manifest; do
                    # Extract arch from something like .../image:tag-os-arch
                    arch_suffix_from_tag=$(echo "$image_in_manifest" | rev | cut -d- -f1,2 | rev) # e.g., linux-amd64 or arm64 (needs care)
                    # This extraction is fragile if tag itself contains hyphens.
                    # A more robust way: from $current_target_arch_sync used when creating the tag
                    # This requires storing the arch along with the tagged image name if not easily parsable.
                    # For now, let's assume a simple os-arch suffix or just arch.
                    # It's better to re-derive from the original $current_target_arch_sync for each image.
                    # This part needs refinement if annotation is critical and tags are complex.

                    # Simplified: We know $MANIFEST_IMAGES_ARGS are based on $local_image_full-${arch//\//-}
                    # We'd need to iterate through TARGET_ARCHS that were actually pushed.
                done < "$arch_images_for_manifest_file" # Placeholder for actual annotation loop

                if ! docker manifest push "$local_image_full"; then
                    log_message "错误: 推送 manifest $local_image_full 失败。"
                    docker manifest rm "$local_image_full" 2>/dev/null || true 
                else
                    log_message "成功创建并推送多架构 manifest: $local_image_full"
                fi
            fi
        elif [ "$arch_count" -gt 0 ]; then 
             log_message "警告: $hub_image_full 的部分或所有待同步架构未能成功推送到仓库，无法创建 manifest。"
        fi

        log_message "清理为 $local_image_full 创建的本地带架构后缀的镜像..."
        if [ -f "$arch_images_for_manifest_file" ]; then
            while IFS= read -r arch_image_to_remove; do
                log_message "移除本地镜像: $arch_image_to_remove"
                docker rmi "$arch_image_to_remove" 2>/dev/null || true
            done < "$arch_images_for_manifest_file"
        fi
        rm -f "$archs_to_sync_file" "$arch_images_for_manifest_file"
    done < "$LATEST_FILE"
    log_message "镜像同步执行完毕"
}

# --- 主逻辑 ---
ensure_dependencies
log_config

if [ "$1" = "sync" ]; then
    sync_images
    exit 0
fi

if [ "$SYNC_ON_START" = "true" ]; then
    log_message "SYNC_ON_START 为 true，执行首次同步..."
    sync_images
    log_message "首次同步执行完毕。"
fi

if command -v crond > /dev/null; then
    log_message "设置 cron 任务: '$CRON_SCHEDULE /app/sync_images.sh sync >> $SYNC_LOG_FILE 2>&1'"
    echo "" > /etc/crontabs/root
    echo "$CRON_SCHEDULE /app/sync_images.sh sync >> $SYNC_LOG_FILE 2>&1" >> /etc/crontabs/root
    log_message "启动 crond 服务..."
    crond -f -l 8 -L "$CRON_LOG_FILE" &
else
    log_message "警告: crond 未找到，无法设置定时任务。"
fi

log_message "脚本启动完成。查看日志: $SYNC_LOG_FILE, $CRON_LOG_FILE, $PYTHON_CRAWLER_LOG_FILE"
tail -F "$SYNC_LOG_FILE" "$CRON_LOG_FILE" "$PYTHON_CRAWLER_LOG_FILE" /dev/null
