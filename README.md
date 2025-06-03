# Docker 镜像同步工具

这是一个用于将 Docker Hub 上的镜像同步到私有 Docker Registry 的工具，基于 docker:dind 镜像修改构建。通过 Python 脚本爬取 Docker Hub 上的镜像分类，生成镜像列表，并同步到私有 Registry。

## 功能特点

- 支持从 Docker Hub 同步镜像到私有 Registry
- 支持定时同步（通过 cron 表达式配置）
- 支持代理配置
- 支持启动时立即同步选项
- 支持自定义目标 Registry
- 支持多架构镜像同步（amd64/arm64）
- 支持自定义同步镜像数量限制
- 支持 Docker Hub 分类镜像爬取
- 支持镜像标签过滤和保留策略

## 项目地址

- Github：[https://github.com/sqing33/docker_image_sync_to_registry](https://github.com/sqing33/docker_image_sync_to_registry)
- DockerHub：[https://hub.docker.com/r/sqing33/docker-image-sync-to-registry](https://hub.docker.com/r/sqing33/docker-image-sync-to-registry)
- CSDN：
- Bilibili：

## 快速开始

1. 克隆仓库：

```bash
git clone https://github.com/sqing33/docker_image_sync_to_registry.git
cd docker_image_sync_to_registry
```

2. 配置环境：

   - 编辑 `docker-compose.yml` 文件，设置必要的环境变量
   - 配置 `daemon.json` 文件，设置 Registry 地址和镜像加速

3. 启动服务：

```bash
docker-compose up -d
```

## 配置说明

### 1. docker-compose.yml 配置

```yaml
services:
  image-sync:
    image: sqing33/docker-image-sync-to-registry # ghcr.io/sqing33/docker-image-sync-to-registry
    container_name: docker-image-sync-to-registry
    privileged: true
    environment:
      - REGISTRY_URL=http://registry:5000 # 镜像仓库地址
      - CRON_SCHEDULE=0 4 * * * # 每天凌晨4点执行
      - SYNC_ON_START=true # 容器启动时立即同步
      - TARGET_ARCH=linux/amd64 # 目标架构(linux/amd64,linux/arm64)
      - REMOVE_LIBRARY_PREFIX_ON_LOCAL=true # 是否移除本地镜像的library/前缀
      - MAX_PAGES_PER_CATEGORY=1 # 控制 Python 脚本爬取的页数
      - CRAWL_AFTER_CUSTOM_IMAGES=true # 拉取custom_images镜像列表之后是否继续爬取DockerHub
      - HTTP_PROXY=http://192.168.1.100:7890
      - HTTPS_PROXY=http://192.168.1.100:7890
      - NO_PROXY=localhost,127.0.0.1,docker.1panel.live,docker.1ms.run,http://registry:5000
    volumes:
      - /etc/timezone:/etc/timezone:ro # 容器时区同步宿主机
      - /etc/localtime:/etc/localtime:ro # 容器时间同步宿主机
      - /vol1/1000/Docker/docker-image-sync-to-registry/daemon.json:/etc/docker/daemon.json # 设置容器Docker加速源
      - /vol3/1000/Docker镜像仓库/docker缓存:/var/lib/docker/overlay2 # 挂载容器Docker下载镜像的目录
      - /vol1/1000/Docker/docker-image-sync-to-registry/custom_images.txt:/app/custom_images.txt:ro # 自定义镜像列表文件
```

###### 附带部署 registry 的示例：

```yaml
version: "3"

services:
  registry:
    image: registry:2 # ghcr.io/sqing33/registry
    container_name: registry
    restart: always
    ports:
      - 1500:5000
    volumes:
      - /vol3/1000/Docker镜像仓库:/var/lib/registry
    environment:
      - REGISTRY_STORAGE_DELETE_ENABLED=true # 启用删除功能
    networks:
      - registry

  registry-ui:
    image: quiq/registry-ui # ghcr.io/sqing33/registry-ui
    container_name: registry-ui
    restart: always
    volumes:
      - /vol1/1000/Docker/registry/config.yml:/opt/config.yml:ro
    ports:
      - 1501:8000
    networks:
      - registry

  docker-image-sync:
    image: sqing33/docker-image-sync-to-registry # ghcr.io/sqing33/docker-image-sync-to-registry
    container_name: docker-image-sync-to-registry
    privileged: true
    environment:
      - REGISTRY_URL=http://registry:5000 # 镜像仓库地址
      - CRON_SCHEDULE=0 4 * * * # 每天凌晨4点执行
      - SYNC_ON_START=true # 容器启动时立即同步
      - TARGET_ARCH=linux/amd64 # 目标架构(linux/amd64,linux/arm64)
      - REMOVE_LIBRARY_PREFIX_ON_LOCAL=true # 是否移除本地镜像的library/前缀
      - MAX_PAGES_PER_CATEGORY=1 # 控制 Python 脚本爬取的页数
      - CRAWL_AFTER_CUSTOM_IMAGES=true # 拉取custom_images镜像列表之后是否继续爬取DockerHub
      - HTTP_PROXY=http://192.168.1.100:7890
      - HTTPS_PROXY=http://192.168.1.100:7890
      - NO_PROXY=localhost,127.0.0.1,docker.1panel.live,docker.1ms.run,http://registry:5000
    volumes:
      - /etc/timezone:/etc/timezone:ro # 容器时区同步宿主机
      - /etc/localtime:/etc/localtime:ro # 容器时间同步宿主机
      - /vol1/1000/Docker/docker-image-sync-to-registry/daemon.json:/etc/docker/daemon.json # 设置容器Docker加速源
      - /vol3/1000/Docker镜像仓库/docker缓存:/var/lib/docker/overlay2 # 挂载容器Docker下载镜像的目录
      - /vol1/1000/Docker/docker-image-sync-to-registry/custom_images.txt:/app/custom_images.txt:ro # 自定义镜像列表文件
    networks:
      - registry

networks:
  registry:
    name: registry
```

### 2. daemon.json 配置

```json
{
  "registry-mirrors": ["https://docker.1panel.live", "https://docker.1ms.run"],
  "insecure-registries": ["[镜像仓库地址]"]
}
```

### 3. 参数信息

| 参数名                         | 说明                                                  | 默认值              | 是否必填 |
| ------------------------------ | ----------------------------------------------------- | ------------------- | -------- |
| REGISTRY_URL                   | 镜像仓库地址                                          | -                   | 是       |
| CRON_SCHEDULE                  | 定时同步的 cron 表达式                                | 0 4 \* \* \*        | 是       |
| SYNC_ON_START                  | 容器启动时是否立即同步                                | true                | 是       |
| TARGET_ARCH                    | 目标架构(linux/amd64,linux/arm64)                     | linux/amd64         | 是       |
| REMOVE_LIBRARY_PREFIX_ON_LOCAL | 是否移除本地镜像的 library/ 前缀                      | false               | 是       |
| MAX_PAGES_PER_CATEGORY         | 控制 Python 脚本爬取的页数                            | 5                   | 是       |
| CRAWL_AFTER_CUSTOM_IMAGES      | 拉取 custom_images 镜像列表之后是否继续爬取 DockerHub | true                | 是       |
| HTTP_PROXY                     | HTTP 代理地址                                         | -                   | 否       |
| HTTPS_PROXY                    | HTTPS 代理地址                                        | -                   | 否       |
| NO_PROXY                       | 不使用代理的地址列表                                  | localhost,127.0.0.1 | 否       |

### 4. 挂载卷说明

| 挂载路径                 | 说明                           | 是否必填 |
| ------------------------ | ------------------------------ | -------- |
| /etc/timezone            | 容器时区同步宿主机             | 是       |
| /etc/localtime           | 容器时间同步宿主机             | 是       |
| /etc/docker/daemon.json  | 设置容器 Docker 加速源         | 是       |
| /var/lib/docker/overlay2 | 挂载容器 Docker 下载镜像的目录 | 否       |
| /app/custom_images.txt   | 自定义镜像列表文件             | 否       |

## 项目结构

```
.
├── Dockerfile              # Docker 镜像构建文件
├── docker-compose.yml      # Docker Compose 配置文件
├── daemon.json            # Docker daemon 配置文件
├── config.yml             # Registry UI 配置文件
├── docker_hub_crawler.py  # Docker Hub 爬虫脚本
└── sync_images.sh         # 镜像同步脚本
```

## 工作原理

1. 爬虫模块（docker_hub_crawler.py）：

   - 爬取 Docker Hub 上的镜像分类
   - 提取镜像名称和标签信息
   - 支持分页获取和去重处理

2. 同步模块（sync_images.sh）：

   - 读取 custom_images.txt 中的镜像列表
   - 读取爬虫生成的镜像列表
   - 使用 docker pull 拉取镜像
   - 使用 docker tag 重命名镜像
   - 使用 docker push 推送到私有仓库

## 项目截图

## 故障排除

1. 同步失败检查项：

   - 网络连接状态
   - 代理配置正确性
   - Registry 可访问性
   - 磁盘空间充足性
   - 认证信息有效性

2. 查看日志：

```bash
# 查看容器日志
docker logs docker-image-sync-to-registry

# 查看同步脚本日志
docker exec docker-image-sync-to-registry cat /var/log/sync_images.log
```

3. 常见问题：
   - 网络超时：检查网络连接和代理设置
   - 认证失败：验证 Registry 认证信息
   - 空间不足：清理旧镜像或增加存储空间
