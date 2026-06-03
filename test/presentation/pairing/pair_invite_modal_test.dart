import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/pair_invite.dart';
import 'package:sharer/presentation/pairing/pair_invite_modal.dart';

/// Audit #6 regression: the decline path used to close the modal twice
/// (once via the `declined` stream status, once via a manual call in
/// `_finalize`), popping the route underneath the modal and stacking a
/// duplicate snackbar. These tests drive the close purely through the
/// stream listener (the single source of truth) and assert exactly one
/// pop + one snackbar, including the `_closed` idempotency guard.
PairInvite _invite(PairInviteStatus status) => PairInvite(
      inviteId: 'invite-1',
      peerId: 'peer-1',
      peerName: 'Realme',
      fingerprint: '123456',
      role: PairInviteRole.responder,
      status: status,
      expiresAt: DateTime(2999),
    );

Future<void> _pumpAndOpenModal(
  WidgetTester tester,
  Stream<PairInvite> stream,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pairInviteStreamProvider.overrideWith((ref) => stream),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => PairInviteModal.show(
                ctx,
                invite: _invite(PairInviteStatus.awaitingFingerprint),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(PairInviteModal), findsOneWidget);
}

void main() {
  testWidgets('declined status closes the modal once with one snackbar',
      (tester) async {
    final controller = StreamController<PairInvite>.broadcast();
    addTearDown(controller.close);
    await _pumpAndOpenModal(tester, controller.stream);

    controller.add(_invite(PairInviteStatus.declined));
    await tester.pumpAndSettle();

    expect(find.byType(PairInviteModal), findsNothing,
        reason: 'the modal closed on the declined status');
    expect(find.text('Pairing cancelled.'), findsOneWidget);
    expect(find.text('open'), findsOneWidget,
        reason: 'only the modal was popped; the underlying route survives');
  });

  testWidgets('two declined emissions still close once (_closed guard)',
      (tester) async {
    final controller = StreamController<PairInvite>.broadcast();
    addTearDown(controller.close);
    await _pumpAndOpenModal(tester, controller.stream);

    // Emit twice back-to-back; the idempotency guard must collapse the
    // second close into a no-op so we never over-pop or double-toast.
    controller.add(_invite(PairInviteStatus.declined));
    controller.add(_invite(PairInviteStatus.declined));
    await tester.pumpAndSettle();

    expect(find.byType(PairInviteModal), findsNothing);
    expect(find.text('Pairing cancelled.'), findsOneWidget,
        reason: 'exactly one snackbar despite two declined emissions');
    expect(find.text('open'), findsOneWidget,
        reason: 'the underlying route was never popped');
  });

  testWidgets('audit #45: the fingerprint exposes a digit-by-digit '
      'screen-reader label', (tester) async {
    final controller = StreamController<PairInvite>.broadcast();
    addTearDown(controller.close);
    final handle = tester.ensureSemantics();
    await _pumpAndOpenModal(tester, controller.stream);

    // _invite's fingerprint is '123456' — the modal must announce it spelled
    // out so a blind user can compare the verification number across devices.
    expect(find.bySemanticsLabel('Verification number: 1 2 3 4 5 6'),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('opening the modal reads the verification number aloud',
      (tester) async {
    final controller = StreamController<PairInvite>.broadcast();
    addTearDown(controller.close);

    // SemanticsService.sendAnnouncement sends an AnnounceSemanticsEvent map
    // over SystemChannels.accessibility — capture it.
    final announced = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility,
            (message) async {
      if (message is Map && message['type'] == 'announce') {
        announced.add((message['data'] as Map)['message'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility, null));

    await _pumpAndOpenModal(tester, controller.stream);

    expect(announced, isNotEmpty);
    expect(announced.first, contains('Verification number'));
    expect(announced.first, contains('1 2 3 4 5 6'));
  });

  testWidgets('opening the modal fires a subtle light-impact haptic',
      (tester) async {
    final controller = StreamController<PairInvite>.broadcast();
    addTearDown(controller.close);

    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String? ?? '');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpAndOpenModal(tester, controller.stream);

    expect(haptics, contains('HapticFeedbackType.lightImpact'));
  });
}
