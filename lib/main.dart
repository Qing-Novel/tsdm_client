import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fpdart/fpdart.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_theme/system_theme.dart';
import 'package:tsdm_client/app.dart';
import 'package:tsdm_client/cmd.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/color.dart';
import 'package:tsdm_client/features/local_notice/callback.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/proxy_provider/proxy_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/background_service_helper.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/window_configs.dart';
import 'package:tsdm_client/utils/window_events.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main(List<String> args) async => runZonedGuarded(() async => _boot(args), _ensureHandled);

Future<void> _boot(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  await initLogger();

  // 把上次运行遗留下来的后台服务日志合并进主日志。
  await importBackgroundLogToTalker();

  final presentError = FlutterError.onError;
  FlutterError.onError = (details) {
    final where = details.context?.toDescription();
    talker.handle(
      details.exception,
      details.stack,
      'FlutterError in ${details.library ?? 'widgets'}${where == null ? '' : ': $where'}',
    );
    presentError?.call(details);
  };

  parseCmdArgs(args);

  talker.debug('------------------- start app -------------------');
  listenAndroidWindowEvents();
  await initProviders();

  final settings = getIt.get<SettingsRepository>().currentSettings;

  final settingsLocale = settings.locale;
  final locale = AppLocale.values.firstWhereOrNull((v) => v.languageTag == settingsLocale);
  if (locale == null) {
    await LocaleSettings.useDeviceLocale();
  } else {
    await LocaleSettings.setLocale(locale);
  }

  // 把当前 locale 写到 SharedPreferences，供后台服务选通知文案。
  if (isAndroid) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentLocale = locale?.languageTag ?? LocaleSettings.currentLocale.languageTag;
      await prefs.setString('background_locale', currentLocale);
    } on Exception catch (_) {
      // 写失败不能影响启动。
    }
  }

  if (isDesktop) {
    await windowManager.ensureInitialized();
    if (!cmdArgs.noWindowConfigs) {
      await desktopUpdateWindowTitle();
      await desktopRestoreWindowBounds(settings);
    }
  }

  final useSystemTheme = settings.accentColorFollowSystem;

  final color = switch (useSystemTheme) {
    true => await SystemTheme.accentColor.load().then((_) => SystemTheme.accentColor.accent.valueA),
    false => settings.accentColor,
  };
  final themeModeIndex = settings.themeMode;

  final autoCheckin = settings.autoCheckin;
  final autoSyncNoticeSeconds = settings.autoSyncNoticeSeconds;

  flnp = FlutterLocalNotificationsPlugin();
  if (isAndroid) {
    await flnp.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
      ),
      onDidReceiveNotificationResponse: onLocalNotificationOpened,
    );
    await deleteLegacyLocalNoticeChannel();
    await rememberNotificationLaunch();
    if (autoSyncNoticeSeconds > 0) {
      final granted = await flnp
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      talker.info('boot notification permission granted=$granted');
    }
  }

  final fontFamily = settings.fontFamily;
  final checkUpdate = settings.enableUpdateCheckOnStartup;

  if (settings.useDetectedProxyWhenStartup) {
    await getIt.get<ProxyProvider>().updateProxy();
  }

  if (isAndroid) {
    // 把后台服务写的时间戳同步给前台数据库，避免点击通知后重复拉取同一批消息。
    await _syncBackgroundLastFetchTime();
    await initializeBackgroundService();
    if (await isBackgroundServiceEnabled()) {
      await startBackgroundService();
    }
  }

  runApp(
    TranslationProvider(
      child: ResponsiveBreakpoints.builder(
        breakpoints: WindowSize.values.map((e) => Breakpoint(start: e.start, end: e.end, name: e.name)).toList(),
        child: App(
          color,
          themeModeIndex,
          autoCheckin: autoCheckin,
          autoSyncNoticeSeconds: autoSyncNoticeSeconds,
          fontFamily: fontFamily,
          checkUpdate: checkUpdate,
        ),
      ),
    ),
  );
}

/// 把后台服务写进 SharedPreferences 的"上次拉取时间"同步给前台数据库。
///
/// 后台在独立 isolate 里跑，写不了数据库，只能写 SharedPreferences。
/// 前台启动时，如果 SharedPreferences 的时间戳更新，就把它写回数据库，
/// 这样前台的自动同步就不会重复拉取后台已经拉过的消息。
Future<void> _syncBackgroundLastFetchTime() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getInt('background_login_uid');
    if (uid == null || uid <= 0) {
      return;
    }
    final bgLastFetch = prefs.getInt('background_last_fetch_time_$uid');
    if (bgLastFetch == null || bgLastFetch <= 0) {
      return;
    }

    final storage = getIt.get<StorageProvider>();
    final dbTimeEither = await storage.fetchLastFetchNoticeTime(uid).run();
    final dbTime = dbTimeEither.getOrElse((_) => null);
    final dbSec = dbTime == null ? 0 : dbTime.millisecondsSinceEpoch ~/ 1000;
    if (bgLastFetch > dbSec) {
      await storage
          .updateLastFetchNoticeTime(uid, DateTime.fromMillisecondsSinceEpoch(bgLastFetch * 1000))
          .run();
      talker.debug(
        'sync background last fetch time to db: uid=${"$uid".obscured(4)} '
        'db=$dbSec bg=$bgLastFetch',
      );
    }
  } on Exception catch (e, st) {
    talker.handle(e, st, 'sync background last fetch time failed');
  }
}

void _ensureHandled(Object exception, StackTrace? stackTrace) => talker.handle(exception, stackTrace);
