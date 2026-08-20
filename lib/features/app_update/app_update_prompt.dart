import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../providers.dart';
import '../../services/app_update/app_update_service.dart';

bool _appUpdateCheckInProgress = false;

/// Checks for an EmuHub APK update and presents the verified install flow.
Future<void> checkAndShowAppUpdate(
  BuildContext context,
  WidgetRef ref, {
  bool manual = false,
}) async {
  if (_appUpdateCheckInProgress) return;
  final settings = ref.read(appSettingsProvider);
  if (!manual && !settings.appAutoUpdateEnabled) return;

  final service = ref.read(appUpdateServiceProvider);
  if (!manual && !service.isAutomaticCheckDue()) return;

  _appUpdateCheckInProgress = true;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (manual) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('正在检查 EmuHub 新版本…'),
        duration: Duration(seconds: 30),
      ),
    );
  } else {
    await service.markAutomaticCheckStarted();
  }

  try {
    final result = await service.checkForUpdate();
    if (!context.mounted) return;
    if (manual) messenger?.hideCurrentSnackBar();

    final release = result.release;
    if (release == null) {
      if (manual) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('当前已经是最新版本')),
        );
      }
      return;
    }

    if (!manual &&
        !service.shouldPromptAutomatically(release.buildNumber)) {
      return;
    }
    await service.markPrompted(release.buildNumber);
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AppUpdateDialog(
        service: service,
        release: release,
        installedBuildNumber: result.installedBuildNumber,
      ),
    );
  } catch (error) {
    if (!context.mounted || !manual) return;
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text('应用更新检查失败：$error')),
    );
  } finally {
    _appUpdateCheckInProgress = false;
  }
}

enum _UpdateStage {
  ready,
  downloading,
  verifying,
  waitingPermission,
  error,
}

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({
    required this.service,
    required this.release,
    required this.installedBuildNumber,
  });

  final AppUpdateService service;
  final AppRelease release;
  final int installedBuildNumber;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog>
    with WidgetsBindingObserver {
  _UpdateStage _stage = _UpdateStage.ready;
  double _progress = 0;
  String? _message;
  File? _downloadedApk;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _stage == _UpdateStage.waitingPermission) {
      unawaited(_continueAfterPermission());
    }
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _stage = _UpdateStage.downloading;
      _progress = 0;
      _message = '正在下载经过固定签名的安装包…';
    });
    try {
      final apk = await widget.service.downloadAndVerify(
        widget.release,
        onProgress: (received, total) {
          if (!mounted) return;
          final expected = total > 0 ? total : widget.release.apkSize;
          setState(() {
            _progress = expected > 0
                ? (received / expected).clamp(0.0, 1.0).toDouble()
                : 0.0;
          });
        },
        onVerifying: () {
          if (!mounted) return;
          setState(() {
            _stage = _UpdateStage.verifying;
            _progress = 1;
            _message = '下载完成，正在校验 SHA-256…';
          });
        },
      );
      if (!mounted) return;
      _downloadedApk = apk;
      await _launchInstaller();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _UpdateStage.error;
        _message = '更新失败：$error';
      });
    }
  }

  Future<void> _launchInstaller() async {
    final apk = _downloadedApk;
    if (apk == null || _installing) return;
    _installing = true;
    try {
      final result = await widget.service.installApk(apk);
      if (!mounted) return;
      switch (result) {
        case AppInstallResult.launched:
          Navigator.of(context).pop();
          return;
        case AppInstallResult.permissionRequired:
          setState(() {
            _stage = _UpdateStage.waitingPermission;
            _message = '请在系统页面允许“安装未知应用”。返回 EmuHub 后会继续安装。';
          });
          return;
        case AppInstallResult.unsupported:
          setState(() {
            _stage = _UpdateStage.error;
            _message = '当前设备无法调起 APK 安装程序。';
          });
          return;
      }
    } finally {
      _installing = false;
    }
  }

  Future<void> _continueAfterPermission() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || _stage != _UpdateStage.waitingPermission) return;
    if (await widget.service.canRequestPackageInstalls()) {
      await _launchInstaller();
    } else if (mounted) {
      setState(() {
        _message = '尚未获得安装权限。点击“继续安装”可重新打开授权页面。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final release = widget.release;
    final sizeMb = release.apkSize > 0
        ? (release.apkSize / 1024 / 1024).toStringAsFixed(1)
        : '未知';
    final busy = _stage == _UpdateStage.downloading ||
        _stage == _UpdateStage.verifying;

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.system_update),
          SizedBox(width: 10),
          Expanded(child: Text('发现 EmuHub 新版本')),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${release.name} · $sizeMb MB',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                '当前：v${AppConstants.appVersion} '
                '(构建 ${widget.installedBuildNumber})\n'
                '最新：${release.tagName} (构建 ${release.buildNumber})',
                style: theme.textTheme.bodySmall,
              ),
              if (release.notes.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('更新说明', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                SelectableText(
                  release.notes,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (_stage != _UpdateStage.ready) ...[
                const SizedBox(height: 18),
                if (busy) LinearProgressIndicator(value: _progress),
                if (busy) const SizedBox(height: 8),
                Text(
                  _message ?? '',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _stage == _UpdateStage.error
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!busy)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后'),
          ),
        if (_stage == _UpdateStage.ready)
          FilledButton.icon(
            onPressed: _downloadAndInstall,
            icon: const Icon(Icons.download),
            label: const Text('下载并安装'),
          ),
        if (_stage == _UpdateStage.error)
          FilledButton(
            onPressed: _downloadAndInstall,
            child: const Text('重试'),
          ),
        if (_stage == _UpdateStage.waitingPermission)
          FilledButton(
            onPressed: _launchInstaller,
            child: const Text('继续安装'),
          ),
      ],
    );
  }
}
