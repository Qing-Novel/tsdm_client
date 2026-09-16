import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/notification_type.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

part 'notification_bloc.mapper.dart';
part 'notification_event.dart';
part 'notification_state.dart';

/// SharedPreferences 标志：后台已经推送过通知，前台首次拉取时跳过重复推送。
const String _skipNextNotificationKey = 'background_notified_skip_next';

/// Read state of freshly [fetched] notices reconciled with the copies already [stored] for the same user.
List<NoticeV2> reconcileNoticeReadState({required List<NoticeV2> fetched, required List<NoticeEntity> stored}) {
  final byNid = {for (final e in stored) e.nid: e};
  return fetched.map((n) {
    final local = byNid[n.id];
    if (local == null) {
      return n;
    }
    if (n.timestamp > local.timestamp) {
      return n.copyWith(alreadyRead: false);
    }
    return n.copyWith(alreadyRead: local.alreadyRead ?? false);
  }).toList();
}

List<PersonalMessageV2> reconcilePersonalMessageReadState({
  required List<PersonalMessageV2> fetched,
  required List<PersonalMessageEntity> stored,
}) {
  final byPeer = {for (final e in stored) e.peerUid: e};
  return fetched.map((m) {
    final local = byPeer[m.peerUid];
    if (local == null || m.timestamp > local.timestamp || m.data != local.data) {
      return m;
    }
    return m.copyWith(alreadyRead: m.alreadyRead || local.alreadyRead);
  }).toList();
}

List<BroadcastMessageV2> reconcileBroadcastMessageReadState({
  required List<BroadcastMessageV2> fetched,
  required List<BroadcastMessageEntity> stored,
}) {
  final byPmid = {for (final e in stored) e.pmid: e};
  return fetched.map((m) {
    final local = byPmid[m.pmid];
    if (local == null) {
      return m.copyWith(alreadyRead: false);
    }
    return m.copyWith(alreadyRead: local.alreadyRead ?? false);
  }).toList();
}

NotificationV2 freshNotifications({required NotificationV2 fetched, required NotificationGroup stored}) {
  final notices = {for (final e in stored.noticeList) e.nid: e};
  final conversations = {for (final e in stored.personalMessageList) e.peerUid: e};
  final broadcasts = {for (final e in stored.broadcastMessageList) e.pmid: e};
  return fetched.copyWith(
    noticeList: fetched.noticeList.where((n) {
      final local = notices[n.id];
      return local == null || n.timestamp > local.timestamp;
    }).toList(),
    personalMessageList: fetched.personalMessageList.where((m) {
      if (m.sender) {
        return false;
      }
      final local = conversations[m.peerUid];
      return local == null || m.timestamp > local.timestamp || m.data != local.data;
    }).toList(),
    broadcastMessageList: fetched.broadcastMessageList.where((m) => !broadcasts.containsKey(m.pmid)).toList(),
  );
}

typedef PersistedNotification = ({NotificationV2 fresh, NotificationV2 reconciled, NotificationStateInfo unread});

Future<PersistedNotification> persistFetchedNotification({
  required StorageProvider storage,
  required int uid,
  required NotificationV2 fetched,
}) async {
  final stored = await storage.fetchNotificationSince(uid: uid, timestamp: 0).run();
  final fresh = freshNotifications(fetched: fetched, stored: stored);
  final info = fetched.copyWith(
    noticeList: reconcileNoticeReadState(fetched: fetched.noticeList, stored: stored.noticeList),
    personalMessageList: reconcilePersonalMessageReadState(
      fetched: fetched.personalMessageList,
      stored: stored.personalMessageList,
    ),
    broadcastMessageList: reconcileBroadcastMessageReadState(
      fetched: fetched.broadcastMessageList,
      stored: stored.broadcastMessageList,
    ),
  );
  talker.debug(
    'saving notification: uid=${"$uid".obscured(4)} notice=${info.noticeList.length} '
    'personalMessage=${info.personalMessageList.length} '
    'broadcastMessage=${info.broadcastMessageList.length}',
  );
  await storage
      .saveNotification(
        uid: uid,
        notificationGroup: NotificationGroup(
          noticeList: info.noticeList
              .map(
                (e) => NoticeEntity(
                  uid: uid,
                  nid: e.id,
                  timestamp: e.timestamp,
                  data: e.data,
                  alreadyRead: e.alreadyRead,
                ),
              )
              .toList(),
          personalMessageList: info.personalMessageList
              .map(
                (e) => PersonalMessageEntity(
                  uid: uid,
                  timestamp: e.timestamp,
                  data: e.data,
                  peerUid: e.peerUid,
                  peerUsername: e.peerUsername,
                  sender: e.sender,
                  alreadyRead: e.alreadyRead,
                ),
              )
              .toList(),
          broadcastMessageList: info.broadcastMessageList
              .map(
                (e) => BroadcastMessageEntity(
                  uid: uid,
                  timestamp: e.timestamp,
                  data: e.data,
                  pmid: e.pmid,
                  alreadyRead: e.alreadyRead,
                ),
              )
              .toList(),
        ),
      )
      .run();
  return (fresh: fresh, reconciled: info, unread: await countUnreadNotification(storage: storage, uid: uid));
}

Future<NotificationStateInfo> countUnreadNotification({required StorageProvider storage, required int uid}) async {
  final group = await storage.fetchNotificationSince(uid: uid, timestamp: 0).run();
  return NotificationStateInfo(
    notice: group.noticeList.where((e) => !(e.alreadyRead ?? false)).length,
    personalMessage: group.personalMessageList.where((e) => !e.alreadyRead).length,
    broadcastMessage: group.broadcastMessageList.where((e) => !(e.alreadyRead ?? false)).length,
  );
}

typedef _Emit = Emitter<NotificationState>;

class NotificationBloc extends Bloc<NotificationEvent, NotificationState> with LoggerMixin {
  NotificationBloc({
    required NotificationRepository notificationRepository,
    required NotificationInfoRepository infoRepository,
    required AuthenticationRepository authRepo,
    required StorageProvider storageProvider,
  }) : _notificationRepository = notificationRepository,
       _infoRepository = infoRepository,
       _authRepo = authRepo,
       _storageProvider = storageProvider,
       super(const NotificationState()) {
    on<NotificationEvent>(
      (e, emit) => switch (e) {
        NotificationUpdateAllRequested() => _onUpdateAllRequested(emit),
        NotificationReloadFromStorageRequested() => _onReloadFromStorageRequested(emit),
        NotificationRecordFetchTimeRequested(:final time) => _onRecordFetchTimeRequested(time),
        NotificationMarkReadRequested(:final recordMark) => _onMarkReadRequested(emit, recordMark),
        NotificationInfoFetched(:final info) => _onNoticeInfoFetched(emit, info),
        NotificationMarkTypeReadRequested(:final markAsRead, :final markType) => _onMarkTypeReadRequested(
          emit,
          markType,
          markAsRead: markAsRead,
        ),
        NotificationDeleteNoticeRequested(:final uid, :final nid) => _onDeleteNotice(emit, uid: uid, nid: nid),
        NotificationDeletePersonalMessageRequested(:final uid, :final peerUid) => _onDeletePersonalMessage(
          emit,
          uid: uid,
          peerUid: peerUid,
        ),
        NotificationDeleteBroadcastMessageRequested(:final uid, :final pmid) => _onDeleteBroadcastMessage(
          emit,
          uid: uid,
          pmid: pmid,
        ),
      },
    );

    _notificationRepository.status.listen((info) => add(NotificationInfoFetched(info)));
  }

  final NotificationRepository _notificationRepository;
  final NotificationInfoRepository _infoRepository;
  final AuthenticationRepository _authRepo;
  final StorageProvider _storageProvider;

  Future<void> _onUpdateAllRequested(_Emit emit) async {
    if (state.status == NotificationStatus.loading) {
      debug('update all notifications, skipped because already loading one');
      return;
    }
    debug('updating all notifications...');

    emit(state.copyWith(status: NotificationStatus.loading));
    final uid = _authRepo.currentUser?.uid;
    if (uid == null) {
      info('skip request of update notification: uid is null, not authorized');
      return;
    }
    final lastFetchTimeEither = await _storageProvider.fetchLastFetchNoticeTime(uid).run();
    int? timestamp;
    if (lastFetchTimeEither.isRight()) {
      final datetime = lastFetchTimeEither.unwrap();
      if (datetime != null) {
        timestamp = datetime.millisecondsSinceEpoch ~/ 1000;
      }
      debug('fetch notification since ${datetime?.yyyyMMDDHHMMSS()}');
    } else {
      debug('fetch notification with default duration');
    }

    await _notificationRepository.fetchNotificationV2(uid: uid, timestamp: timestamp).run();
  }

  Future<void> _onNoticeInfoFetched(_Emit emit, NotificationInfoState infoState) async {
    late NotificationV2 info;
    late final int uid;
    switch (infoState) {
      case NotificationInfoStateFailure():
        emit(state.copyWith(status: NotificationStatus.failure));
        final currentUid = _authRepo.currentUser?.uid;
        if (currentUid != null) {
          await _publishUnreadCounts(currentUid);
        }
        return;
      case NotificationInfoStateLoading():
        emit(state.copyWith(status: NotificationStatus.loading));
        return;
      case NotificationInfoStateSuccess(uid: final u, info: final i):
        info = i;
        uid = u;
    }

    emit(state.copyWith(status: NotificationStatus.loading));

    final latestMessageTime = info.latestTimestamp();

    final persisted = await persistFetchedNotification(storage: _storageProvider, uid: uid, fetched: info);
    final fresh = persisted.fresh;
    info = persisted.reconciled;

    final currentUid = _authRepo.currentUser?.uid;
    if (currentUid != uid) {
      debug('Async gap meets uid changes, do NOT update state.');
      return;
    }

    final localNoticeData = await _storageProvider.fetchNotificationSince(uid: uid, timestamp: 0).run();
    debug(
      'load local notification: '
      'notice=${localNoticeData.noticeList.length} '
      'personalMessage=${localNoticeData.personalMessageList.length} '
      'broadcastMessage=${localNoticeData.broadcastMessageList.length}',
    );

    localNoticeData.personalMessageList.removeWhere(
      (x) => x.uid == uid && info.personalMessageList.any((y) => y.peerUid == x.peerUid),
    );

    localNoticeData.noticeList.removeWhere((x) => info.noticeList.any((y) => x.uid == uid && x.nid == y.id));
    localNoticeData.broadcastMessageList.removeWhere(
      (x) => info.broadcastMessageList.any((y) => x.uid == uid && x.pmid == y.pmid),
    );

    final allNotice = [
      ...info.noticeList,
      ...localNoticeData.noticeList.map(
        (e) => NoticeV2(id: e.nid, timestamp: e.timestamp, data: e.data, alreadyRead: e.alreadyRead ?? false),
      ),
    ];
    final allPersonalMessage = [
      ...info.personalMessageList,
      ...localNoticeData.personalMessageList.map(
        (e) => PersonalMessageV2(
          timestamp: e.timestamp,
          data: e.data,
          peerUid: e.peerUid,
          peerUsername: e.peerUsername,
          sender: e.sender,
          alreadyRead: e.alreadyRead,
        ),
      ),
    ];
    final allBroadcastMessage = [
      ...info.broadcastMessageList,
      ...localNoticeData.broadcastMessageList.map(
        (e) =>
            BroadcastMessageV2(timestamp: e.timestamp, data: e.data, pmid: e.pmid, alreadyRead: e.alreadyRead ?? false),
      ),
    ];

    _infoRepository.updateInfo(
      unreadNoticeCount: allNotice.where((e) => !e.alreadyRead).length,
      unreadPersonalMessageCount: allPersonalMessage.where((e) => !e.alreadyRead).length,
      unreadBroadcastMessageCount: allBroadcastMessage.where((e) => !e.alreadyRead).length,
    );

    // 如果后台服务已经推送过这条通知，跳过这次的前台推送。
    final prefs = await SharedPreferences.getInstance();
    final skipNext = prefs.getBool(_skipNextNotificationKey) ?? false;
    if (skipNext) {
      await prefs.setBool(_skipNextNotificationKey, false);
      debug('skip local notification: background already pushed it');
    } else if (fresh.personalMessageList.isNotEmpty) {
      _infoRepository.updateAutoSyncInfo(
        NotificationAutoSyncInfoPm(
          user: fresh.personalMessageList.last.peerUsername,
          msg: fresh.personalMessageList.last.data.truncate(40, ellipsis: true),
          notice: fresh.noticeList.length,
          personalMessage: fresh.personalMessageList.length,
          broadcastMessage: fresh.broadcastMessageList.length,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else if (fresh.broadcastMessageList.isNotEmpty) {
      _infoRepository.updateAutoSyncInfo(
        NotificationAutoSyncInfoBm(
          msg: fresh.broadcastMessageList.last.data.truncate(40, ellipsis: true),
          notice: fresh.noticeList.length,
          personalMessage: fresh.personalMessageList.length,
          broadcastMessage: fresh.broadcastMessageList.length,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else if (fresh.noticeList.isNotEmpty) {
      _infoRepository.updateAutoSyncInfo(
        NotificationAutoSyncInfoNotice(
          msg: parseHtmlDocument(fresh.noticeList.last.data).body?.innerText.truncate(40, ellipsis: true) ?? '<null>',
          notice: fresh.noticeList.length,
          personalMessage: fresh.personalMessageList.length,
          broadcastMessage: fresh.broadcastMessageList.length,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    emit(
      state.copyWith(
        status: NotificationStatus.success,
        noticeList: allNotice,
        personalMessageList: allPersonalMessage,
        broadcastMessageList: allBroadcastMessage,
        latestTime: latestMessageTime,
      ),
    );
  }

  Future<void> _onMarkTypeReadRequested(_Emit emit, NotificationType markType, {required bool markAsRead}) async {
    final uid = _authRepo.currentUser?.uid;
    if (uid == null) {
      error('intend to mark all notice for user but uid not found');
      return;
    }

    emit(state.copyWith(status: NotificationStatus.loading));

    await _storageProvider.markTypeAsRead(notificationType: markType, uid: uid, alreadyRead: markAsRead).run();
    await _publishUnreadCounts(uid);

    switch (markType) {
      case NotificationType.notice:
        final list = state.noticeList.map((e) => e.copyWith(alreadyRead: markAsRead)).toList();
        emit(state.copyWith(status: NotificationStatus.success, noticeList: list));
      case NotificationType.personalMessage:
        final list = state.personalMessageList.map((e) => e.copyWith(alreadyRead: markAsRead)).toList();
        emit(state.copyWith(status: NotificationStatus.success, personalMessageList: list));
      case NotificationType.broadcastMessage:
        final list = state.broadcastMessageList.map((e) => e.copyWith(alreadyRead: markAsRead)).toList();
        emit(state.copyWith(status: NotificationStatus.success, broadcastMessageList: list));
    }
  }

  Future<void> _onRecordFetchTimeRequested(DateTime time) async {
    if (time.year < 2025) {
      warning('not going to record fetch time as we are in 2025, at least');
      return;
    }

    final uid = _authRepo.currentUser?.uid;
    if (uid == null) {
      error('failed to update last fetch notice time: uid not found');
      return;
    }
    final stored = (await _storageProvider.fetchLastFetchNoticeTime(uid).run()).getOrElse((_) => null);
    if (stored != null && !time.isAfter(stored)) {
      debug('keep last fetch notification time ${stored.yyyyMMDDHHMMSS()}, ${time.yyyyMMDDHHMMSS()} is not later');
      return;
    }
    debug('update last fetch notification time to ${time.yyyyMMDDHHMMSS()}');
    await _storageProvider.updateLastFetchNoticeTime(uid, time).run();
  }

  Future<void> _onMarkReadRequested(_Emit emit, RecordMark recordMark) async {
    debug('mark notice: $recordMark');
    final int uid;
    final AsyncVoidEither task;
    switch (recordMark) {
      case RecordMarkNotice(uid: final u, :final nid, alreadyRead: final read):
        uid = u;
        final list = state.noticeList.toList();
        final targetIndex = list.indexWhere((e) => e.id == nid);
        if (targetIndex >= 0) {
          list[targetIndex] = list[targetIndex].copyWith(alreadyRead: read);
          emit(state.copyWith(noticeList: list));
        }
        task = _storageProvider.markNoticeAsRead(uid: uid, nid: nid, read: read);
      case RecordMarkPersonalMessage(uid: final u, :final peerUid, alreadyRead: final read):
        uid = u;
        final list = state.personalMessageList.toList();
        final targetIndex = list.indexWhere((e) => e.peerUid == peerUid);
        if (targetIndex >= 0) {
          list[targetIndex] = list[targetIndex].copyWith(alreadyRead: read);
          emit(state.copyWith(personalMessageList: list));
        }
        task = _storageProvider.markPersonalMessageAsRead(uid: uid, peerUid: peerUid, read: read);
      case RecordMarkBroadcastMessage(uid: final u, :final timestamp, alreadyRead: final read):
        uid = u;
        final list = state.broadcastMessageList.toList();
        final targetIndex = list.indexWhere((e) => e.timestamp == timestamp);
        if (targetIndex >= 0) {
          list[targetIndex] = list[targetIndex].copyWith(alreadyRead: read);
          emit(state.copyWith(broadcastMessageList: list));
        }
        task = _storageProvider.markBroadcastMessageAsRead(uid: uid, timestamp: timestamp, read: read);
    }
    await task.run();
    await _publishUnreadCounts(uid);
  }

  Future<void> _publishUnreadCounts(int uid) async {
    if (_authRepo.currentUser?.uid != uid) {
      debug('skip publishing unread counts: not the current user');
      return;
    }
    final unread = await countUnreadNotification(storage: _storageProvider, uid: uid);
    _infoRepository.updateInfo(
      unreadNoticeCount: unread.notice,
      unreadPersonalMessageCount: unread.personalMessage,
      unreadBroadcastMessageCount: unread.broadcastMessage,
    );
  }

  Future<void> _onReloadFromStorageRequested(_Emit emit) async {
    if (state.status == NotificationStatus.loading) {
      debug('reload notification from storage, skipped because already loading');
      return;
    }
    final uid = _authRepo.currentUser?.uid;
    if (uid == null) {
      debug('skip reload notification from storage: uid is null, not authorized');
      return;
    }
    final group = await _storageProvider.fetchNotificationSince(uid: uid, timestamp: 0).run();
    if (_authRepo.currentUser?.uid != uid) {
      debug('Async gap meets uid changes, do NOT update state.');
      return;
    }
    final noticeList = group.noticeList
        .map((e) => NoticeV2(id: e.nid, timestamp: e.timestamp, data: e.data, alreadyRead: e.alreadyRead ?? false))
        .toList();
    final personalMessageList = group.personalMessageList
        .map(
          (e) => PersonalMessageV2(
            timestamp: e.timestamp,
            data: e.data,
            peerUid: e.peerUid,
            peerUsername: e.peerUsername,
            sender: e.sender,
            alreadyRead: e.alreadyRead,
          ),
        )
        .toList();
    final broadcastMessageList = group.broadcastMessageList
        .map(
          (e) => BroadcastMessageV2(
            timestamp: e.timestamp,
            data: e.data,
            pmid: e.pmid,
            alreadyRead: e.alreadyRead ?? false,
          ),
        )
        .toList();
    debug(
      'reload notification from storage: notice=${noticeList.length} personalMessage=${personalMessageList.length} '
      'broadcastMessage=${broadcastMessageList.length}',
    );
    emit(
      state.copyWith(
        status: NotificationStatus.success,
        noticeList: noticeList,
        personalMessageList: personalMessageList,
        broadcastMessageList: broadcastMessageList,
      ),
    );
  }

  Future<void> _onDeleteNotice(_Emit emit, {required int uid, required int nid}) async {
    emit(state.copyWith(noticeList: state.noticeList.toList()..removeWhere((e) => e.id == nid)));
    await _storageProvider.deleteNotice(uid: uid, nid: nid).run();
  }

  Future<void> _onDeletePersonalMessage(_Emit emit, {required int uid, required int peerUid}) async {
    emit(
      state.copyWith(personalMessageList: state.personalMessageList.toList()..removeWhere((e) => e.peerUid == peerUid)),
    );
    await _storageProvider.deletePersonalMessage(uid: uid, peerUid: peerUid).run();
  }

  Future<void> _onDeleteBroadcastMessage(_Emit emit, {required int uid, required int pmid}) async {
    emit(state.copyWith(broadcastMessageList: state.broadcastMessageList.toList()..removeWhere((e) => e.pmid == pmid)));
    await _storageProvider.deleteBroadcastMessage(uid: uid, pmid: pmid).run();
  }

  @override
  Future<void> close() async {
    await _notificationRepository.dispose();
    return super.close();
  }
}
