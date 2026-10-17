# luci-app-dockercompose

OpenWrt / LuCI 的 Docker Compose 项目管理界面。在 LuCI 侧边栏「Docker」分类下提供一个内嵌管理页，可视化管理本机 `docker compose` 项目：查看状态、启动/停止、编辑配置、更新镜像、查看日志、一键复制等。

> 个人自用项目，AI 辅助开发，随缘维护。

## 功能特性

- **项目卡片列表**：展示所有 Compose 项目，运行中/停止/未创建状态一目了然，四色徽标表示更新检查状态
- **状态实时检查**：每个项目显示运行时长、容器状态、端口与挂载信息
- **更新检查**：一键检查镜像是否有新版本（支持镜像加速源）
- **手动更新 / 自动更新**：升级指定项目；可配置自动更新脚本，按需拉取新镜像
- **镜像加速**：通过 `/etc/config/dockerd` 配置镜像加速地址（如 docker.1panel.live / docker.1ms.run 等），检查与更新共用同一加速通路
- **配置编辑**：图形化编辑 `docker-compose.yml`（端口、挂载、环境变量）
- **新建 / 删除 / 复制项目**：基于现有项目复制，自动映射路径
- **日志查看**：容器日志弹窗，一键复制
- **移动端适配**：小屏单列卡片、按钮换行，适配 280px ~ 1024px 全宽度手机

## 依赖

- OpenWrt / iStoreOS（LuCI 环境）
- `luci-base`
- `docker` + `docker-compose`（Docker CLI 插件）

## 目录结构

```
luci-app-dockercompose/
├── dockercompose.lua     # LuCI 控制器（RPC 后端，调用 docker/docker compose）
├── index.html            # 前端主界面（单文件应用）
├── view.js               # LuCI iframe 渲染器（嵌入主界面）
├── pinyin_map.js         # 汉字拼音映射数据（GB2312 一级字，由 pypinyin 生成，MIT）
├── gen_pinyin.py         # 生成 pinyin_map.js 的脚本（pypinyin, MIT）
├── menu.json             # LuCI 侧边栏菜单定义
├── acl.json              # LuCI 权限（ACL）定义
├── build_ipk.py          # ipk 打包脚本（OpenWrt gzip-tar 格式）
└── LICENSE               # GPL-2.0
```

## 安装

```sh
# 方式一：安装已打包的 ipk
opkg install luci-app-dockercompose_*.ipk

# 方式二：手动放置源码文件
#   dockercompose.lua  → /usr/lib/lua/luci/controller/dockercompose.lua
#   index.html         → /www/luci-static/resources/dockercompose/index.html
#   view.js            → /www/luci-static/resources/view/docker/dockercompose.js
#   pinyin_map.js      → /www/luci-static/resources/dockercompose/pinyin_map.js
#   menu.json          → /usr/share/luci/menu.d/luci-app-dockercompose.json
#   acl.json           → /usr/share/rpcd/acl.d/luci-app-dockercompose.json
```

安装后清理 LuCI 缓存并重启 Web 服务：

```sh
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
/etc/init.d/uhttpd restart
```

## 构建 ipk

```sh
python3 build_ipk.py
# 生成 luci-app-dockercompose_<版本>_all.ipk
```

## 免责声明

本插件以 root / LuCI 管理员权限运行，可执行 Docker 操作，**请勿将 LuCI 页面暴露到公网**。仅供学习与自用，使用风险自负。

## 许可证

[GPL-2.0](LICENSE)
