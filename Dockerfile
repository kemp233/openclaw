# syntax=docker/dockerfile:1.7

# Opt-in extension dependencies at build time (space-separated directory names).
ARG OPENCLAW_EXTENSIONS=""
ARG OPENCLAW_VARIANT=default
ARG OPENCLAW_DOCKER_APT_UPGRADE=1
ARG OPENCLAW_NODE_BOOKWORM_IMAGE="node:24-bookworm@sha256:3a09aa6354567619221ef6c45a5051b671f953f0a1924d1f819ffb236e520e6b"
ARG OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE="node:24-bookworm-slim@sha256:e8e2e91b1378f83c5b2dd15f0247f34110e2fe895f6ca7719dbb780f929368eb"

# ── 关键修复点：定义 base-default 阶段 ──────────────────────────
# 这样下面的 FROM base-${OPENCLAW_VARIANT} 才能找到目标
FROM ${OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE} AS base-default

# ── Stage 1: Extension Deps ─────────────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS ext-deps
ARG OPENCLAW_EXTENSIONS
COPY extensions /tmp/extensions
RUN mkdir -p /out && \
    for ext in $OPENCLAW_EXTENSIONS; do \
      if [ -f "/tmp/extensions/$ext/package.json" ]; then \
        mkdir -p "/out/$ext" && \
        cp "/tmp/extensions/$ext/package.json" "/out/$ext/package.json"; \
      fi; \
    done

# ── Stage 2: Build ──────────────────────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS build
RUN set -eux; \
    for attempt in 1 2 3 4 5; do \
      if curl --retry 5 --retry-all-errors --retry-delay 2 -fsSL https://bun.sh/install | bash; then \
        break; \
      fi; \
      if [ "$attempt" -eq 5 ]; then exit 1; fi; \
      sleep $((attempt * 2)); \
    done
ENV PATH="/root/.bun/bin:${PATH}"
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY --from=ext-deps /out/ ./extensions/
RUN --mount=type=cache,id=openclaw-pnpm-store,target=/root/.local/share/pnpm/store,sharing=locked \
    NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile
COPY . .
RUN for dir in /app/extensions /app/.agent /app/.agents; do \
      if [ -d "$dir" ]; then \
        find "$dir" -type d -exec chmod 755 {} +; \
        find "$dir" -type f -exec chmod 644 {} +; \
      fi; \
    done
RUN pnpm canvas:a2ui:bundle || (mkdir -p src/canvas-host/a2ui && echo "stub" > src/canvas-host/a2ui/.bundle.hash)
RUN pnpm build:docker
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# ── Stage 2.5: Assets Pruning ──────────────────────────────────
FROM build AS runtime-assets
RUN CI=true pnpm prune --prod && \
    find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete

# ── Stage 3: Runtime ────────────────────────────────────────────
# 这里现在可以正确识别 base-default 了
FROM base-${OPENCLAW_VARIANT}
ARG OPENCLAW_VARIANT
ARG OPENCLAW_DOCKER_APT_UPGRADE

LABEL org.opencontainers.image.source="https://github.com/openclaw/openclaw" \
  org.opencontainers.image.title="OpenClaw-Quant" \
  org.opencontainers.image.description="OpenClaw with Root permissions and VNPY Skill support"

WORKDIR /app

# 安装核心系统工具
RUN --mount=type=cache,id=openclaw-bookworm-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-bookworm-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    if [ "${OPENCLAW_DOCKER_APT_UPGRADE}" != "0" ]; then \
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends; \
    fi && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      procps hostname curl git lsof openssl ca-certificates sudo

# --- 关键修改 1: 预装编译环境，方便 AI 安装 vnpy ---
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3-dev \
    build-essential \
    gcc \
    g++ \
    cmake \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# 确保文件夹权限归属 root
RUN chown root:root /app

# --- 关键修改 2: 强制固化自定义技能 ---
COPY skills /app/skills

# 从构建阶段复制程序文件
COPY --from=runtime-assets /app/dist ./dist
COPY --from=runtime-assets /app/node_modules ./node_modules
COPY --from=runtime-assets /app/package.json .
COPY --from=runtime-assets /app/openclaw.mjs .
COPY --from=runtime-assets /app/extensions ./extensions
COPY --from=runtime-assets /app/docs ./docs

# 环境变量配置
ENV OPENCLAW_BUNDLED_PLUGINS_DIR=/app/extensions
ENV COREPACK_HOME=/usr/local/share/corepack
RUN install -d -m 0755 "$COREPACK_HOME" && corepack enable

# 浏览器自动化支持
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && apt-get install -y --no-install-recommends xvfb && \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium; \
    fi

# 设置命令行软连接
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw && chmod +x /app/openclaw.mjs

ENV NODE_ENV=production

# --- 关键修改 3: 配置 ROOT 权限 ---
USER root

# 设置 OpenClaw 的家目录为 root 路径
ENV OPENCLAW_STATE_DIR=/root/.openclaw
ENV OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json

HEALTHCHECK --interval=3m --timeout=10s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# 启动命令
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured", "--host", "0.0.0.0"]
