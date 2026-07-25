import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/consoles/console_detail_page.dart';
import '../../features/consoles/consoles_page.dart';
import '../../features/emulator/emulator_detail_page.dart';
import '../../features/favorites/favorites_page.dart';
import '../../features/home/home_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/updates/update_center_page.dart';

/// 全局路由配置。
///
/// 使用 [StatefulShellRoute.indexedStack] 包裹底部导航栏，共 5 个分支（tab）：
/// home（首页）、consoles（机种库）、updates（更新中心）、favorites（收藏）、
/// settings（设置）。每个分支保留各自的导航栈，切换 tab 时状态不丢失。
///
/// 详情页（`/console/:id`、`/emulator/:id`）作为顶层路由，位于 shell 之外，
/// 以全屏形式展示并带有返回按钮。
///
/// 使用方式：
/// ```dart
/// MaterialApp.router(routerConfig: appRouter);
/// ```
final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.home,
  debugLogDiagnostics: true,
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return _ScaffoldWithNavBar(navigationShell: navigationShell);
      },
      branches: <StatefulShellBranch>[
        // 0. 首页
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) => const HomePage(),
            ),
          ],
        ),
        // 1. 机种库
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.consoles,
              builder: (context, state) => const ConsolesPage(),
            ),
          ],
        ),
        // 2. 更新中心
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.updates,
              builder: (context, state) => const UpdateCenterPage(),
            ),
          ],
        ),
        // 3. 收藏
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.favorites,
              builder: (context, state) => const FavoritesPage(),
            ),
          ],
        ),
        // 4. 设置
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.settings,
              builder: (context, state) => const SettingsPage(),
            ),
          ],
        ),
      ],
    ),
    // 机种详情：全屏，位于 shell 之外
    GoRoute(
      path: AppRoutes.consoleDetail,
      builder: (context, state) => ConsoleDetailPage(
        consoleId: state.pathParameters['id']!,
      ),
    ),
    // 模拟器详情：全屏，位于 shell 之外
    GoRoute(
      path: AppRoutes.emulatorDetail,
      builder: (context, state) => EmulatorDetailPage(
        emulatorId: state.pathParameters['id']!,
      ),
    ),
  ],
);

/// 路由配置 Riverpod provider。
///
/// 在 `main.dart` 中通过 `ref.watch(appRouterProvider)` 获取，
/// 保证路由配置与 Riverpod 作用域绑定。
final appRouterProvider = Provider<GoRouter>((ref) {
  return appRouter;
});

/// 路由路径常量。
///
/// 集中管理便于在业务代码中调用 `context.go(AppRoutes.xxx)`。
class AppRoutes {
  AppRoutes._();

  static const String home = '/home';
  static const String consoles = '/consoles';
  static const String consoleDetail = '/console/:id';
  static const String emulatorDetail = '/emulator/:id';
  static const String updates = '/updates';
  static const String favorites = '/favorites';
  static const String settings = '/settings';

  /// 拼接机种详情路径。
  static String consoleDetailOf(String id) => '/console/$id';

  /// 拼接模拟器详情路径。
  static String emulatorDetailOf(String id) => '/emulator/$id';
}

/// 底部导航栏外壳。
///
/// 将 [StatefulNavigationShell] 作为 body 渲染，并在底部提供 5 个 tab 的
/// [NavigationBar]。切换 tab 时调用 [StatefulNavigationShell.goBranch]，
/// 当目标分支已是当前分支时传入 `initialLocation: true` 回到分支根。
class _ScaffoldWithNavBar extends StatelessWidget {
  const _ScaffoldWithNavBar({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) {
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_esports_outlined),
            selectedIcon: Icon(Icons.sports_esports),
            label: '机种',
          ),
          NavigationDestination(
            icon: Icon(Icons.system_update),
            selectedIcon: Icon(Icons.system_update),
            label: '更新',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: '收藏',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
