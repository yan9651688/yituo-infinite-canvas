<p align="center">
  <img src="web/public/yituo-logo.png" width="96" alt="易拓 AI">
</p>

<h1 align="center">易拓画布</h1>

<p align="center">易拓 AI 无限画布工作台 · 图片 / 视频 / 音频 / 文本 / 创作工作流</p>

本仓库是 [tigerowo/infinite-canvas](https://github.com/tigerowo/infinite-canvas) 的易拓 AI 定制版，保留原项目署名与 GNU Affero General Public License v3.0。原项目又基于 [basketikun](https://github.com/basketikun/infinite-canvas) 与 [HuFakai](https://github.com/HuFakai/infinite-canvas) 的版本持续开发。

## 核心功能

- 无限画布：多项目、节点拖拽缩放、连线、小地图、撤销重做、导入导出。
- AI 创作：OpenAI 兼容图片、视频、音频与文本接口，支持参考图、流式响应和任务轮询。
- 创作工作流：公开/个人模板、变量表单、RunningHub 与 ComfyUI。
- Agent：围绕选中节点和上游节点规划创作，并把结果插回画布。
- 素材与提示词：本地素材、账号同步、提示词库和生成历史。
- 导演台：3D 场景、全景环境、机位管理与截图回传。

完整功能见 [功能说明](docs/overview/features.md)，节点操作见 [画布手册](docs/canvas/canvas-node-manual.md)。

## 易拓 AI 嵌入

生产入口：`https://i18n.laoyantongxue.si/infinite-canvas/`。

New API 的聊天配置使用 iframe 打开独立工作台，并注入当前用户的 API Key 与站点地址：

```text
https://i18n.laoyantongxue.si/infinite-canvas/?apiKey={key}&baseUrl={address}
```

工作台读取参数后会立即从地址栏移除密钥，写入浏览器本地“易拓 AI”直连渠道并打开配置确认。未登录时画布项目与“我的素材”保存在浏览器本地；登录本工作台账号且同步可用时才同步到其账号。模型 API Key 默认保存在浏览器本地，模型请求由浏览器直连易拓 AI，不经过画布后端。

## 本地开发

要求 Go 1.25+、Bun 1.4+。

```bash
cp .env.example .env
# 修改 ADMIN_PASSWORD 和 JWT_SECRET
go run .
```

另开终端：

```bash
cd web
bun install --frozen-lockfile
bun run dev
```

访问 `http://localhost:3000`，Go API 默认监听 `8080`。

## Docker 构建

```bash
cp .env.example .env
# 必须修改 ADMIN_PASSWORD 和 JWT_SECRET；DATABASE_DSN 设为 /app/data/infinite-canvas.db
docker compose -f docker-compose.local.yml up -d --build
```

生产镜像默认把 Next.js `basePath` 构建为 `/infinite-canvas`。本地不需要子路径时：

```bash
docker build --build-arg NEXT_PUBLIC_BASE_PATH= -t yituo-infinite-canvas .
```

运行后访问 `http://localhost:3000`。生产数据保存在挂载的 `data/` 目录，不要更换已有环境的 `JWT_SECRET`。

## 校验

```bash
cd web
bun test src/lib/embedded-config.test.ts
bun run build
```

部署文件位于 `deploy/`。正式更新先启动独立候选实例并检查首页、API、嵌入参数与回滚路径，通过后才切换 i18n 路由，不直接覆盖正在服务的实例。

## 开源与来源

- 原项目：[tigerowo/infinite-canvas](https://github.com/tigerowo/infinite-canvas)
- 本定制版源码：[yan9651688/yituo-infinite-canvas](https://github.com/yan9651688/yituo-infinite-canvas)
- 许可：[AGPL-3.0](LICENSE)
- 页面演示素材来自原项目公开仓库，已下载到 `web/public/banners/` 随站点本地提供。
