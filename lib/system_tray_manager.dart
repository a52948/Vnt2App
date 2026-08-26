import 'dart:io';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:vnt2_app/data_persistence.dart';
import 'package:vnt2_app/vnt/vnt_manager.dart';
import 'package:vnt2_app/network_config.dart';
import 'dart:isolate';
import 'package:flutter/material.dart' hide MenuItem;
import 'package:vnt2_app/src/rust/api/vnt_api.dart';

/// 系统托盘管理器 - 提供全局访问的托盘更新功能
class SystemTrayManager with TrayListener {
  static final SystemTrayManager _instance = SystemTrayManager._internal();
  factory SystemTrayManager() => _instance;
  SystemTrayManager._internal();

  bool _initialized = false;

  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 初始化系统托盘。
  Future<void> initialize(String iconPath) async {
    if (!isSupported || _initialized) {
      return;
    }
    trayManager.addListener(this);
    await trayManager.setIcon(iconPath);
    _initialized = true;
    await updateMenu();
    await updateTooltip();
  }

  Future<void> showMainWindow() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return;
    }
    if (Platform.isWindows || Platform.isLinux) {
      await windowManager.setSkipTaskbar(false);
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// 更新系统托盘菜单
  /// [optimisticState] 乐观更新的连接状态，如果为null则使用实际状态
  Future<void> updateMenu({bool? optimisticState}) async {
    if (!isSupported || !_initialized) {
      return;
    }

    final dataPersistence = DataPersistence();
    final configs = await dataPersistence.loadData();
    // 使用乐观状态或实际状态
    final hasConnection = optimisticState ?? vntManager.hasConnection();

    final List<MenuItem> menuItems = [];

    // 连接/断开连���
    if (hasConnection) {
      menuItems.add(MenuItem(
        label: '断开连接',
        onClick: (menuItem) async {
          // 乐观更新：先更新UI为未连接状态
          await updateMenu(optimisticState: false);
          await updateTooltip(optimisticState: false);

          // 执行断开操作
          await vntManager.removeAll();

          // 根据实际状态更新UI
          await updateMenu();
          await updateTooltip();
        },
      ));
    } else {
      menuItems.add(MenuItem(
        label: '连接默认配置',
        onClick: (menuItem) async {
          final defaultKey = await dataPersistence.loadDefaultKey();
          if (defaultKey != null && defaultKey.isNotEmpty) {
            final config =
                configs.where((c) => c.itemKey == defaultKey).firstOrNull;
            if (config != null) {
              await _connectConfig(config);
            }
          }
        },
      ));
    }

    menuItems.add(MenuItem.separator());

    // 配置列表子菜单
    if (configs.isNotEmpty) {
      final List<MenuItem> configMenuItems = [];
      for (final config in configs) {
        configMenuItems.add(MenuItem(
          label: config.configName,
          onClick: (menuItem) async {
            // 如果已有连接，先断开
            if (vntManager.hasConnection()) {
              // 乐观更新：先更新UI为未连接状态
              await updateMenu(optimisticState: false);
              await updateTooltip(optimisticState: false);

              await vntManager.removeAll();
              await Future.delayed(const Duration(milliseconds: 500));
            }
            await _connectConfig(config);
          },
        ));
      }

      menuItems.add(MenuItem.submenu(
        label: '配置列表',
        submenu: Menu(items: configMenuItems),
      ));
      menuItems.add(MenuItem.separator());
    }

    // 显示主界面
    menuItems.add(MenuItem(
      label: '显示主界面',
      onClick: (menuItem) async {
        await showMainWindow();
      },
    ));

    // 隐藏窗口
    menuItems.add(MenuItem(
      label: '隐藏窗口',
      onClick: (menuItem) {
        windowManager.hide();
      },
    ));

    menuItems.add(MenuItem.separator());

    // 退出
    menuItems.add(MenuItem(
      label: '退出',
      onClick: (menuItem) async {
        if (vntManager.hasConnection()) {
          await vntManager.removeAll();
        }
        windowManager.setPreventClose(false);
        await trayManager.destroy();
        exit(0);
      },
    ));

    await trayManager.setContextMenu(Menu(items: menuItems));
  }

  /// 更新系统托盘tooltip
  /// [optimisticState] 乐观更新的连接状态，如果为null则使用实际状态
  Future<void> updateTooltip({bool? optimisticState}) async {
    if (!isSupported || !_initialized) {
      return;
    }

    String tooltip = "VNT2 APP - Virtual Network Tool";

    // 使用乐观状态或实际状态
    final hasConnection = optimisticState ?? vntManager.hasConnection();

    if (hasConnection) {
      // 获取第一个连接的配置
      final vntBox = vntManager.getOne();
      if (vntBox != null) {
        final config = vntBox.getNetConfig();
        if (config != null) {
          tooltip = "VNT2 - ${config.configName} 已连接";
        }
      }
    }

    // AppIndicator 在 Linux 上不支持 tooltip。
    if (!Platform.isLinux) {
      await trayManager.setToolTip(tooltip);
    }
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      showMainWindow();
    } else if (Platform.isMacOS) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows) {
      trayManager.popUpContextMenu();
    } else if (Platform.isMacOS) {
      showMainWindow();
    }
  }

  /// 连接到指定配置
  Future<void> _connectConfig(NetworkConfig config) async {
    try {
      // 乐观更新：先更新UI为已连接状态
      await updateMenu(optimisticState: true);
      await updateTooltip(optimisticState: true);

      final receivePort = ReceivePort();
      bool connectionSuccessful = false;

      receivePort.listen((message) {
        if (message == 'success') {
          connectionSuccessful = true;
          // 连接成功，更新托盘
          updateMenu();
          updateTooltip();
        } else if (message == 'stop') {
          // 连接失败或停止，恢复UI状态
          if (!connectionSuccessful) {
            updateMenu();
            updateTooltip();
          }
        } else if (message is RustErrorInfo) {
          // Disconnect 类型不销毁连接，Rust 层会自动重连
          if (message.code == RustErrorType.disconnect) {
            debugPrint('系统托盘：连接错误（非致命） - ${message.msg}');
            // 不销毁连接，只记录日志
            return;
          }
          // 其他致命错误，恢复UI状态
          if (!connectionSuccessful) {
            updateMenu();
            updateTooltip();
          }
        }
      });

      await vntManager.create(config, receivePort.sendPort);

      // 等待一小段时间检查连接是否成功
      await Future.delayed(const Duration(milliseconds: 100));

      // 如果连接失败，恢复UI状态
      if (!vntManager.hasConnection()) {
        await updateMenu();
        await updateTooltip();
      }
    } catch (e) {
      debugPrint('连接配置失败: $e');
      // 连接失败，恢复UI状态
      await updateMenu();
      await updateTooltip();
    }
  }
}
