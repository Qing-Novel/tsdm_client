// 这些 public 函数被 main.dart 和 settings_page.dart 调用，但分析器穿透不了
// runZonedGuarded 的闭包入口，会把它们误判为 unreachable。
// ignore_for_file: unreachable_from_main
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

/// 前台服务常驻通知使用的通知渠道 ID。
const String notificationChannelId = 'tsdm_foreground';

/// 前台服务常驻通知使用的通知 ID。
const int notificationId = 888;

/// SharedPreferences 中保存开关状态的 key。
const String backgroundServiceEnabledKey = 'enableBackgroundMessageService';

/// 后台服务日志文件的路径。
Future<File> _bgLogFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/bg_service.log');
}

/// 后台服务专用日志：写到独立文件，避免和主 isolate 的 talker 混在一起。
Future<void> _bgLog(String msg) async {
  try {
    final file = await _bgLogFile();
    final line = '[${DateTime.now().toIso8601String()}] $msg\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  } on Exception catch (_) {
    // 日志失败不能影响主流程
  }
}

/// 把后台服务的日志文件内容读取出来，注入到主 isolate 的 talker，
/// 然后清空文件。
///
/// 前台"导出日志"和"查看历史日志"就都能看到后台服务的记录了。
/// 每次应用启动时调用一次即可。
Future<void> importBackgroundLogToTalker() async {
  try {
    final file = await _bgLogFile();
    if (!file.existsSync()) {
      return;
    }
    final content = await file.readAsString();
    if (content.isEmpty) {
      return;
    }
    for (final line in content.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      talker.info('[BG] $line');
    }
    // 清空文件，避免下次启动重复导入
    await file.writeAsString('');
  } on Exception catch (e) {
    talker.handle(e, null, 'import background log failed');
  }
}

/// 读取用户是否开启了后台消息服务。
Future<bool> isBackgroundServiceEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(backgroundServiceEnabledKey) ?? false;
}

/// 查询后台服务是否真的在运行。
Future<bool> isBackgroundServiceRunning() async {
  return FlutterBackgroundService().isRunning();
}

/// 初始化后台服务配置。
///
/// 只做配置，不启动服务。是否运行由设置页面的开关控制。
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const channel = AndroidNotificationChannel(
    notificationChannelId,
    '后台消息服务',
    description: '保持连接以接收论坛消息',
    importance: Importance.low,
  );

  final plugin = FlutterLocalNotificationsPlugin();

  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: '天使动漫',
      initialNotificationContent: '正在后台保持连接...',
      foregroundServiceNotificationId: notificationId,
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
    ),
  );
}

/// 后台服务的入口，运行在独立的 Isolate 中。
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  await _bgLog('=== onStart called ===');
  DartPluginRegistrant.ensureInitialized();

  final enabled = await isBackgroundServiceEnabled();
  await _bgLog('enabled=$enabled');
  if (!enabled) {
    await _bgLog('service disabled, stopping self');
    await service.stopSelf();
    return;
  }

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
  }

  // 后台 isolate 里重新初始化一次本地通知插件
  final flnp = FlutterLocalNotificationsPlugin();
  await flnp.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
    ),
  );
  await _bgLog('flnp initialized');

  Timer? backgroundTimer;

  /// 启动或重启定时器。
  Future<void> startOrRestartTimer() async {
    backgroundTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    final intervalSeconds = prefs.getInt('autoSyncNoticeSeconds') ?? 180;
    await _bgLog('startOrRestartTimer: interval=$intervalSeconds');

    if (intervalSeconds <= 0) {
      await _bgLog('interval <= 0, skip timer');
      return;
    }

    backgroundTimer = Timer.periodic(Duration(seconds: intervalSeconds), (timer) async {
      await _bgLog('timer fired, checking messages');
      try {
        await _checkNewMessages(flnp);
      } on Exception catch (e) {
        await _bgLog('checkNewMessages exception: $e');
      }
    });

    try {
      await _checkNewMessages(flnp);
    } on Exception catch (e) {
      await _bgLog('initial checkNewMessages exception: $e');
    }
  }

  await startOrRestartTimer();

  service.on('stopService').listen((event) {
    unawaited(_bgLog('received stopService'));
    backgroundTimer?.cancel();
    unawaited(service.stopSelf());
  });

  service.on('updateTimer').listen((event) async {
    await _bgLog('received updateTimer');
    await startOrRestartTimer();
  });
}

/// 后台拉取消息的核心逻辑。
Future<void> _checkNewMessages(FlutterLocalNotificationsPlugin flnp) async {
  await _bgLog('_checkNewMessages start');
  final prefs = await SharedPreferences.getInstance();

  final uid = prefs.getInt('background_login_uid');
  await _bgLog('uid=$uid');
  if (uid == null || uid <= 0) {
    await _bgLog('uid null or <= 0, abort');
    return;
  }

  final cookieJson = prefs.getString('background_cookie_$uid');
  await _bgLog('cookie=${cookieJson == null ? "null" : "len=${cookieJson.length}"}');
  if (cookieJson == null || cookieJson.isEmpty) {
    return;
  }
  final cookieMap = Map<String, String>.from(jsonDecode(cookieJson) as Map);

  final lastFetchTime = prefs.getInt('background_last_fetch_time_$uid');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final since = lastFetchTime ?? (now - 3 * 24 * 3600);
  await _bgLog('since=$since lastFetchTime=$lastFetchTime');

  await _bgLog('fetching pages...');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final noticeHtml = await _fetchHtml(client, noticeUrl, cookieMap);
    await _bgLog('notice html len=${noticeHtml.length}');
    final pmHtml = await _fetchHtml(client, personalMessageUrl, cookieMap);
    await _bgLog('pm html len=${pmHtml.length}');
    final bmHtml = await _fetchHtml(client, broadcastMessageUrl, cookieMap);
    await _bgLog('bm html len=${bmHtml.length}');

    final info = NotificationV2.fromDocuments(
      noticeDoc: parseHtmlDocument(noticeHtml),
      personalMessageDoc: parseHtmlDocument(pmHtml),
      broadcastMessageDoc: parseHtmlDocument(bmHtml),
      since: since,
    );
    await _bgLog(
      'parsed: notice=${info.noticeList.length} pm=${info.personalMessageList.length} '
      'bm=${info.broadcastMessageList.length}',
    );

    final total = info.noticeList.length +
        info.personalMessageList.length +
        info.broadcastMessageList.length;

    if (total > 0) {
      final body = '提醒 ${info.noticeList.length} 条，私信 ${info.personalMessageList.length} 条，广播 ${info.broadcastMessageList.length} 条';
      await flnp.show(
        id: 0,
        title: '天使动漫',
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'newNoticeChannelV2',
            '消息通知',
            channelDescription: '收到新消息时提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
      await _bgLog('notification pushed');
    } else {
      await _bgLog('no new messages');
    }

    await prefs.setInt('background_last_fetch_time_$uid', now);
  } on Exception catch (e) {
    await _bgLog('fetch error: $e');
  } finally {
    client.close(force: true);
  }
}

/// 用 dart:io 的 HttpClient 抓取一个页面，带上 Cookie。
Future<String> _fetchHtml(
  HttpClient client,
  String url,
  Map<String, String> cookieMap,
) async {
  final request = await client.getUrl(Uri.parse(url));
  final cookieHeader = _buildCookieHeader(cookieMap);
  if (cookieHeader.isNotEmpty) {
    request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
  }
  request.headers.set(
    HttpHeaders.userAgentHeader,
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  );
  final response = await request.close();
  return response.transform(utf8.decoder).join();
}

/// 把持久化的 Cookie JSON 拼成请求头。
String _buildCookieHeader(Map<String, String> cookieMap) {
  final pairs = <String>[];
  for (final value in cookieMap.values) {
    try {
      final domainMap = jsonDecode(value);
      if (domainMap is Map) {
        for (final pathValue in domainMap.values) {
          if (pathValue is Map) {
            for (final entry in pathValue.entries) {
              pairs.add('${entry.key}=${entry.value}');
            }
          }
        }
      }
    } on FormatException catch (_) {
      // 不是 JSON 就跳过
    }
  }
  return pairs.join('; ');
}

/// 启动后台服务，并等待服务真正起来。
Future<void> startBackgroundService() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(backgroundServiceEnabledKey, true);

  final service = FlutterBackgroundService();
  if (!await service.isRunning()) {
    await service.startService();
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await service.isRunning()) break;
    }
  }
}

/// 停止后台服务。
Future<void> stopBackgroundService() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(backgroundServiceEnabledKey, false);

  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    service.invoke('stopService');
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!await service.isRunning()) break;
    }
  }
}
