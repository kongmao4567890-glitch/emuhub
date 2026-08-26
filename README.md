# EmuHub

模拟器资讯与更新追踪 App —— 覆盖从 Atari 2600 到 Nintendo Switch、PS5 的全世代主机模拟器，同时收录 Android、Windows、Linux、macOS 版本及模拟器管理工具，自动检测各项目是否有新版本并推送通知。

## 功能特性

- **机种库**：120 个机种分类、321 条模拟器/核心/工具记录，覆盖 Atari、FC、SFC、MD、PS、Xbox、Switch、PS5、Sharp MZ 等机种
- **运行平台筛选**：按 Android、Windows、Linux、macOS 浏览模拟器，PC 条目展示对应系统要求
- **平台标签审计**：以官方 README 和 Release 构建资产为依据同步运行平台，避免桌面版本漏标
- **实用工具**：收录游戏库前端、ROM 管理、控制器映射和一体化模拟器套件
- **自动更新检测**：后台定时检查各模拟器最新版本，有新版本推送系统通知
- **多渠道跟踪**：稳定版、开发版、预览版、Canary 与每夜构建按发布时间统一比较
- **更新中心**：集中展示有更新和无更新的模拟器，一键跳转下载
- **模拟器详情**：最新版本、更新日志、下载源、系统要求、兼容性评级
- **收藏订阅**：关注特定模拟器，只接收订阅项的更新通知
- **设置**：检查频率（2/4/6/12 小时）、通知开关、静音时段、仅 Wi-Fi 检查

## 数据源适配器

App 直接从官方数据源检测版本更新（无后端）：

目录扩充会参考 [Emu-France](https://www.emu-france.com/) 等持续更新的模拟器资讯站，但版本、更新说明和下载地址只采用项目官方仓库或官网。

| 数据源类型 | 适用模拟器 | 检测方式 |
|------------|-----------|----------|
| GitHub Releases | PPSSPP、Dolphin、RetroArch、NetherSX2、melonDS、Azahar、Flycast、MAME4droid、DuckStation 等 | Releases 重定向与资源页，API 作为回退 |
| GitLab Releases | EightBitWonders、JollyCV 等 | GitLab.com 或自托管 GitLab Releases API |
| Forgejo Releases | Eden、Ryubing 等 | Forgejo/Gitea Releases API，支持独立 Canary/每夜仓库 |
| Google Play | .emu 系列、ePSXe、FPse、John 系列、Pizza Boy 等 | 解析 Play Store 页面版本号 |
| 官网 | YabaSanshiro 等无 GitHub 的项目 | 解析官网下载页版本号 |

## 技术栈

- **框架**：Flutter (Dart)
- **状态管理**：Riverpod
- **路由**：go_router
- **网络**：Dio
- **数据库**：Drift (SQLite)
- **后台任务**：workmanager
- **本地通知**：flutter_local_notifications
- **版本比较**：内置语义化版本比较器（支持多段版本号和预发布版本）

## 项目结构

```
lib/
├── main.dart                      # 应用入口
├── providers.dart                 # Riverpod providers 集中定义
├── core/
│   ├── constants/app_constants.dart
│   ├── router/app_router.dart     # go_router 路由配置
│   └── theme/app_theme.dart       # Material 3 紫色主题
├── data/
│   ├── models/                    # freezed 数据模型
│   │   ├── console.dart
│   │   ├── emulator.dart
│   │   ├── version_info.dart
│   │   └── emulators_config.dart
│   ├── database/database.dart     # Drift 数据库（收藏表+版本缓存表）
│   └── repositories/settings_repository.dart
├── features/                      # 功能页面
│   ├── home/                      # 首页
│   ├── consoles/                  # 机种库 + 机种详情
│   ├── emulator/                  # 模拟器详情
│   ├── updates/                   # 更新中心（核心）
│   ├── favorites/                 # 收藏
│   └── settings/                  # 设置
├── services/
│   ├── update/
│   │   ├── version_adapter.dart   # 适配器抽象基类
│   │   ├── github_adapter.dart    # GitHub Releases 适配器
│   │   ├── playstore_adapter.dart # Google Play 适配器
│   │   ├── website_adapter.dart   # 官网适配器
│   │   ├── adapter_factory.dart   # 适配器工厂
│   │   ├── version_comparator.dart # 版本号对比
│   │   └── update_service.dart    # 更新检查编排服务
│   ├── notification_service.dart  # 本地通知
│   └── background_task.dart       # WorkManager 后台任务
└── widgets/version_badge.dart     # 共享组件
```

## 快速开始

### 环境要求

- Flutter SDK >= 3.3.0
- Android SDK（版本由当前 Flutter stable SDK 管理）
- Java 17+

### 构建运行

```bash
# 1. 安装依赖
flutter pub get

# 2. 生成代码（freezed / json_serializable / drift / riverpod）
dart run build_runner build --delete-conflicting-outputs

# 3. 运行
flutter run

# 4. 静态分析与测试
flutter analyze
flutter test

# 5. 构建 APK
flutter build apk --release
```

### 代码生成

本项目使用 build_runner 生成以下文件：
- `*.freezed.dart` — 不可变数据模型
- `*.g.dart` — JSON 序列化、Drift 数据库、Riverpod provider
- `database.g.dart` — Drift 表结构

修改数据模型或数据库后需重新运行：
```bash
dart run build_runner build --delete-conflicting-outputs
```
