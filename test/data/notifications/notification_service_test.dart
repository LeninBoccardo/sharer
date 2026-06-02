import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/notifications/notification_service.dart';

void main() {
  // Audit #41: notificationServiceProvider now closes the service on
  // container dispose via ref.onDispose(() => s.dispose()). This pins the
  // dispose() contract that hook relies on: the foreground-responses
  // broadcast controller is closed (listeners get onDone), so a torn-down
  // container can't leak it. Constructing NotificationService() touches no
  // MethodChannel (init() is never called).
  test('dispose closes the responses broadcast stream', () async {
    final service = NotificationService();
    var done = false;
    service.responses.listen(null, onDone: () => done = true);

    await service.dispose();

    expect(done, isTrue,
        reason: 'dispose() must close the responses controller');
  });
}
