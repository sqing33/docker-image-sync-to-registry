# Docker 镜像同步工具

- 这是一个用于将 Docker Hub 上的镜像同步到私有 Docker Registry 的工具，基于 docker:dind 镜像修改构建。
- 通过 python 脚本爬取 Docker Hub 上的镜像分类，生成一个镜像列表，通过这个镜像列表同步镜像到私有 Registry。
- 该工具支持定时同步，支持 amd64 与 arm64 架构，但是同步到仓库的镜像架构只能与部署此 Docker 的机器的架构一致。

## 功能特点

- 支持从 Docker Hub 同步镜像到私有 Registry
- 支持定时同步（通过 cron 表达式配置）
- 支持代理配置
- 支持启动时立即同步选项
- 支持自定义目标 Registry

## 系统要求

- Docker
- Docker Compose
- 足够的磁盘空间用于存储镜像

## 配置说明

1. 编辑 `docker-compose.yml` 文件，根据需要修改以下环境变量：
- `REGISTRY_URL`: 目标 Registry 地址
- `CRON_SCHEDULE`: 同步时间计划（cron 表达式）
- `SYNC_ON_START`: 是否在启动时执行同步
- `TARGET_ARCH`: 目标架构
- `HTTP_PROXY`: HTTP 代理地址
- `HTTPS_PROXY`: HTTPS 代理地址
- `NO_PROXY`: 不使用代理的地址列表
- `MAX_PAGES`: 设置获取 DockerHub 镜像列表最大页数，默认为5

2. 配置 Docker daemon：
确保 `daemon.json` 中配置了正确的加速地址 registry-mirrors 和私有仓库地址 insecure-registries。

### docker-compose.yml 配置

```yaml
services:
  image-sync:
    image: sqing33/docker_image_async_to_registry
    container_name: docker_image_async_to_registry
    network_mode: host
    privileged: true
    environment:
      - REGISTRY_URL=[私有仓库地址REGISTRY_URL]
      - CRON_SCHEDULE=0 0 * * *  # 每天0点执行
      - SYNC_ON_START=true  # 是否在启动时执行同步
      - TARGET_ARCH=linux/amd64  # 目标架构
      - HTTP_PROXY=http://192.168.1.100:7890
      - HTTPS_PROXY=http://192.168.1.100:7890
      - NO_PROXY=localhost,127.0.0.1,docker.1panel.live,[私有仓库地址REGISTRY_URL]
      - MAX_PAGES=3  # 设置获取 DockerHub 镜像列表最大页数，默认为5
    volumes:
      - /vol1/1000/Docker/docker_image_async_to_registry/daemon.json:/etc/docker/daemon.json
    restart: always
```

### daemon.json 配置

```json
{
  "registry-mirrors": [
    "https://docker.1panel.live"
  ],
  "insecure-registries": [
    "[私有仓库地址REGISTRY_URL]" 
  ]
}
```

## 项目结构

```
.
├── Dockerfile              # Docker 镜像构建文件
├── docker-compose.yml      # Docker Compose 配置文件
├── daemon.json            # Docker daemon 配置文件
├── docker_hub_crawler.py  # Python 爬虫脚本
└── sync_images.sh         # 镜像同步脚本
```

## 注意事项

1. 确保目标 Registry 已经正确配置并可访问
2. 如果使用代理，请确保代理服务器可用
3. 建议定期检查同步日志，确保同步任务正常运行
4. 确保有足够的磁盘空间用于存储同步的镜像

## 故障排除

1. 如果同步失败，请检查：
   - 网络连接是否正常
   - 代理配置是否正确
   - Registry 是否可访问
   - 磁盘空间是否充足

2. 查看容器日志：
```bash
docker logs docker_image_async_to_registry
```
