FROM docker:dind

# 安装Python和必要的依赖
RUN apk add --no-cache \
  python3 \
  py3-pip \
  py3-requests \
  bash \
  jq \
  curl

# 复制Python脚本和shell脚本
COPY docker_hub_crawler.py /app/
COPY sync_images.sh /app/

# 设置工作目录
WORKDIR /app

# 设置脚本权限
RUN chmod +x /app/sync_images.sh

# 创建启动脚本
RUN printf '#!/bin/sh\n\
  # 清理旧的 Docker PID 文件 (如果存在)\n\
  echo "正在清理旧的 Docker PID 文件..."\n\
  rm -f /var/run/docker.pid\n\
  rm -f /var/run/docker.sock.lock\n\
  \n\
  # 启动 Docker 守护进程\n\
  echo "正在启动 Docker 守护进程..."\n\
  dockerd > /var/log/dockerd.log 2>&1 &\n\
  \n\
  # 等待 Docker 守护进程准备就绪\n\
  echo "等待 Docker 守护进程启动..."\n\
  timeout=60\n\
  while ! docker info > /dev/null 2>&1; do\n\
  if [ $timeout -le 0 ]; then\n\
  echo "错误: Docker 守护进程启动超时"\n\
  echo "请检查日志 /var/log/dockerd.log 获取详细错误信息"\n\
  tail -n 50 /var/log/dockerd.log\n\
  exit 1\n\
  fi\n\
  timeout=$((timeout-1))\n\
  sleep 1\n\
  done\n\
  echo "Docker 守护进程已启动"\n\
  \n\
  # 执行同步脚本\n\
  echo "开始执行同步脚本..."\n\
  exec /app/sync_images.sh\n' > /app/entrypoint.sh && \
  chmod +x /app/entrypoint.sh

# 设置入口点
ENTRYPOINT ["/app/entrypoint.sh"] 
