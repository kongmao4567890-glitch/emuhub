# EmuHub

模拟器资讯与更新追踪 App —— 覆盖从 Atari 2600 到 Nintendo Switch 的全世代主机模拟器，自动检测各模拟器是否有新版本并推送通知。

## 功能特性

- **机种库**：18+ 机种分类（FC/SFC/MD/GBA/N64/PS1/PS2/PSP/NDS/3DS/Switch/Dreamcast 等），50+ 款模拟器
- **自动更新检测**：后台定时检查各模拟器最新版本，有新版本推送系统通知
- **更新中心**：集中展示有更新和无更新的模拟器，一键跳转下载
- **模拟器详情**：版本历史、更新日志、下载源、系统要求、兼容性评级
- **收藏订阅**：关注特定模拟器，只接收订阅项的更新通知
- **设置**：检查频率（2/4/6/12 小时）、通知开关、静音时段、仅 Wi-Fi 检查

## 数据源适配器

App 直接从三个官方数据源检测版本更新（无后端）：

| 数据源类型 | 适用模拟器 | 检测方式 |
|------------|-----------|----------|
| GitHub Releases | PPSSPP、Dolphin、RetroArch、NetherSX2、melonDS、Azahar、Flycast、MAME4droid、DuckStation、Eden 等 | GitHub API `/repos/{owner}/{repo}/releases/latest` |
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
- **版本比较**：pub_semver

## 项目结构

```
lib/
├── main.dart                      # 应用入口
├── app.dart
├── providers.dart                 # Riverpod providers 集中定义
├── core/
│   ├── constants/app_constants.dart
│   ├── router/app_router.dart     # go_router 路由配置
│   └── theme/app_theme.dart       # Material 3 紫色主题
├── data/
│   ├── assets/emulators.json      # 内置模拟器配置清单（18机种/47模拟器）
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
- Android SDK (compileSdk 34, minSdk 21)
- Java 17+

### 构建运行

```bash
# 1. 安装依赖
flutter pub get

# 2. 生成代码（freezed / json_serializable / drift / riverpod）
dart run build_runner build --delete-conflicting-outputs

# 3. 运行
flutter run

# 4. 构建 APK
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

## 设计文档

完整设计文档见 `docs/superpowers/specs/2026-07-25-emuhub-android-design.md`。
