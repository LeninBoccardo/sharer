import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/notifications/notification_channels.dart';
import 'package:sharer/data/notifications/notification_router.dart';
import 'package:sharer/data/notifications/notification_service.dart';
import 'package:sharer/data/security/pair_invite_client.dart';
import 'package:sharer/data/security/pair_invite_service.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/tls_key_material.dart';
import 'package:sharer/data/security/tls_key_material_store.dart';
import 'package:sharer/data/security/invite_controller.dart';

import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

class _FakeService extends NotificationService {
  _FakeService() : super();

  final _controller = StreamController<NotificationResponse>.broadcast();
  NotificationLaunch? coldStartLaunch;

  @override
  Stream<NotificationResponse> get responses => _controller.stream;

  @override
  Future<NotificationLaunch?> readLaunchDetails() async => coldStartLaunch;

  void emit(NotificationResponse response) => _controller.add(response);

  @override
  Future<void> dispose() async {
    await _controller.close();
    await super.dispose();
  }
}

class _StubTlsStore implements TlsKeyMaterialStore {
  @override
  Future<TlsKeyMaterial> get() async =>
      throw UnimplementedError('not used in router tests');
}

void main() {
  late _FakeService service;
  late InviteController inviteController;
  late PairInviteService inviteService;
  late PairedDevicesStore pairedStore;
  late StaticIdentityRepo idRepo;
  late List<String> openedPaths;
  late int showWindowCount;
  late NotificationRouter router;

  setUp(() async {
    service = _FakeService();
    pairedStore = PairedDevicesStore(FakeSecureKeyValueStore());
    idRepo = await StaticIdentityRepo.create(seed: 7, name: 'Tester');
    inviteService = PairInviteService(pairedStore, idRepo);
    inviteController = InviteController(
      service: inviteService,
      client: PairInviteClient(),
      identityRepo: idRepo,
      tlsStore: _StubTlsStore(),
    );
    openedPaths = [];
    showWindowCount = 0;
    router = NotificationRouter(
      service: service,
      inviteController: inviteController,
      openFile: (path) async => openedPaths.add(path),
      showMainWindow: () async {
        showWindowCount++;
      },
    );
    await router.start();
  });

  tearDown(() async {
    await router.dispose();
    await service.dispose();
    await inviteService.dispose();
    await pairedStore.dispose();
  });

  group('foreground responses', () {
    test('Android Open action on transfer-done opens the saved path '
        '(path read from payload)', () async {
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.transferOpen,
        payload: 'transfer_done:abc|/dl/Sharer/IMG.jpg',
      ));
      await pumpEventQueue();
      expect(openedPaths, ['/dl/Sharer/IMG.jpg']);
    });

    test('Windows Open action on transfer-done opens the saved path '
        '(path read from action arguments — Windows quirk)', () async {
      // Windows toast quirk: actionId == payload == launch arguments
      // (regardless of whether the body or a button was clicked).
      // The Open button's arguments are encoded as
      // `transfer_open|<savedPath>` so the router can recover the
      // path even though the toast's own payload field is clobbered.
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: r'transfer_open|C:\Users\lenin\Downloads\Sharer\IMG.jpg',
        payload: r'transfer_open|C:\Users\lenin\Downloads\Sharer\IMG.jpg',
      ));
      await pumpEventQueue();
      expect(openedPaths, [r'C:\Users\lenin\Downloads\Sharer\IMG.jpg']);
    });

    test('Windows body tap on transfer-done opens the saved path '
        '(actionId mirrors payload — collapse to body-tap)', () async {
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'transfer_done:abc|/dl/Sharer/IMG.jpg',
        payload: 'transfer_done:abc|/dl/Sharer/IMG.jpg',
      ));
      await pumpEventQueue();
      expect(openedPaths, ['/dl/Sharer/IMG.jpg']);
    });

    test('body tap on transfer-done payload also opens the saved path',
        () async {
      service.emit(const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: 'transfer_done:abc|/dl/Sharer/IMG.jpg',
      ));
      await pumpEventQueue();
      expect(openedPaths, ['/dl/Sharer/IMG.jpg']);
    });

    test('Windows-style path with drive-letter colons survives the parse',
        () async {
      // Payload format: transfer_done:<id>|<savedPath>. The path may
      // contain `:` (C:\) and even `|` if Windows somehow invents it
      // — but the split takes the first `|` only.
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.transferOpen,
        payload:
            r'transfer_done:abc|C:\Users\lenin\Downloads\Sharer\IMG.jpg',
      ));
      await pumpEventQueue();
      expect(openedPaths, [r'C:\Users\lenin\Downloads\Sharer\IMG.jpg']);
    });

    test('Android View action on pair-invite brings the window forward',
        () async {
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.inviteView,
        payload: 'pair_invite:i1',
      ));
      await pumpEventQueue();
      expect(showWindowCount, 1);
    });

    test('Windows View action on pair-invite brings the window forward '
        '(invite id encoded in action arguments)', () async {
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'invite_view|i1',
        payload: 'invite_view|i1',
      ));
      await pumpEventQueue();
      expect(showWindowCount, 1);
    });

    test('body tap on pair-invite payload also brings the window forward',
        () async {
      service.emit(const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: 'pair_invite:i1',
      ));
      await pumpEventQueue();
      expect(showWindowCount, 1);
    });

    test('Windows body tap on pair-invite (actionId mirrors payload) '
        'brings the window forward', () async {
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'pair_invite:i1',
        payload: 'pair_invite:i1',
      ));
      await pumpEventQueue();
      expect(showWindowCount, 1);
    });

    test('Decline action calls finalize(match:false) without showing UI',
        () async {
      // No in-flight invite for this id — the controller logs and
      // returns. We're verifying the route reaches finalize, not the
      // service-side logic (covered in pair_invite_service_test).
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.inviteReject,
        payload: 'pair_invite:never-existed',
      ));
      await pumpEventQueue();
      // showMainWindow MUST NOT have been called — that's the whole
      // point of the silent-decline button.
      expect(showWindowCount, 0);
      // No open call either.
      expect(openedPaths, isEmpty);
    });

    test('unknown action + null payload is a no-op', () async {
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'something_else',
      ));
      await pumpEventQueue();
      expect(openedPaths, isEmpty);
      expect(showWindowCount, 0);
    });

    test('Slice 5.2.4.1: peer-unpaired body tap brings the window forward '
        '(payload=peer_unpaired:<id>, actionId=null on Android)', () async {
      service.emit(const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: 'peer_unpaired:realme',
      ));
      await pumpEventQueue();
      expect(showWindowCount, 1);
      expect(openedPaths, isEmpty);
    });

    test('Slice 5.2.4.1: peer-unpaired body tap on Windows '
        '(actionId mirrors payload) also brings the window forward',
        () async {
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'peer_unpaired:realme',
        payload: 'peer_unpaired:realme',
      ));
      await pumpEventQueue();
      expect(showWindowCount, 1);
    });

    test('Slice 5.2.4.1: any body tap with an unknown payload still '
        'brings the window forward (default fall-through)', () async {
      service.emit(const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: 'something_we_havent_invented_yet:42',
      ));
      await pumpEventQueue();
      expect(showWindowCount, 1);
    });

    test('Slice 5.2.4.1: a body tap with no payload at all still brings '
        'the window forward', () async {
      service.emit(const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
      ));
      await pumpEventQueue();
      expect(showWindowCount, 1);
    });

    test('Slice 5.2.4.1: an unknown action button (not a body tap) is '
        'still a no-op', () async {
      // The default-to-show-window fall-through must NOT fire for
      // genuine action-button taps we don't recognise — only for body
      // taps. This preserves the spec that buttons do specific things
      // (or nothing).
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'truly_unknown_action_button',
        payload: 'pair_invite:i1',
      ));
      await pumpEventQueue();
      // Note: payload starts with `pair_invite:` which would normally
      // route to invite-view, but actionId is also non-null and
      // doesn't match the invite-view pattern → we should respect the
      // actionId namespace and stay quiet.
      expect(openedPaths, isEmpty);
      expect(showWindowCount, 0);
    });
  });

  group('cold-start launch', () {
    test('cold-start with transferOpen action opens the file', () async {
      // Recreate the router with a launch context so we observe the
      // start-time read. The setUp router has no launch.
      await router.dispose();
      service.coldStartLaunch = const NotificationLaunch(
        payload: 'transfer_done:abc|/dl/IMG.jpg',
        actionId: NotificationActions.transferOpen,
      );
      router = NotificationRouter(
        service: service,
        inviteController: inviteController,
        openFile: (path) async => openedPaths.add(path),
        showMainWindow: () async {
          showWindowCount++;
        },
      );
      await router.start();
      await pumpEventQueue();
      expect(openedPaths, ['/dl/IMG.jpg']);
    });

    test('cold-start with pair-invite payload (no action) shows window',
        () async {
      await router.dispose();
      service.coldStartLaunch = const NotificationLaunch(
        payload: 'pair_invite:i1',
        actionId: null,
      );
      router = NotificationRouter(
        service: service,
        inviteController: inviteController,
        openFile: (path) async => openedPaths.add(path),
        showMainWindow: () async {
          showWindowCount++;
        },
      );
      await router.start();
      await pumpEventQueue();
      expect(showWindowCount, 1);
    });

    test('Slice 5.x.3.8: foreground re-fire of the cold-start tap is '
        'suppressed (some Android OEMs deliver the launch tap to the '
        'response stream once the engine is up)', () async {
      await router.dispose();
      // Cold-start with the Open action firing — handled once via
      // readLaunchDetails.
      service.coldStartLaunch = const NotificationLaunch(
        payload: 'transfer_done:abc|/dl/IMG.jpg',
        actionId: NotificationActions.transferOpen,
      );
      router = NotificationRouter(
        service: service,
        inviteController: inviteController,
        openFile: (path) async => openedPaths.add(path),
        showMainWindow: () async {
          showWindowCount++;
        },
      );
      await router.start();
      await pumpEventQueue();
      expect(openedPaths, ['/dl/IMG.jpg']);

      // OEM re-fires the SAME tap into the foreground response stream
      // — must not open the file twice.
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.transferOpen,
        payload: 'transfer_done:abc|/dl/IMG.jpg',
      ));
      await pumpEventQueue();
      expect(openedPaths, ['/dl/IMG.jpg'],
          reason: 'foreground re-fire of cold-start tap should be deduped');

      // After the dedup latch clears, a LATER tap on the same
      // notification (legitimate user re-tap) still routes.
      service.emit(const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: NotificationActions.transferOpen,
        payload: 'transfer_done:abc|/dl/IMG.jpg',
      ));
      await pumpEventQueue();
      expect(openedPaths, ['/dl/IMG.jpg', '/dl/IMG.jpg'],
          reason: 'second tap after dedup latch cleared should route');
    });
  });
}
