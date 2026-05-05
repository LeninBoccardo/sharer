import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Slice 5.2.2: top-level entry point for the foreground task isolate.
///
/// `flutter_foreground_task` requires a `@pragma('vm:entry-point')`
/// callback that registers a [TaskHandler]; the package spawns it in
/// a separate isolate when the FG service starts. We don't run any
/// real work in that isolate — the HTTP server, mDNS listener and
/// pair-invite service all live in the main isolate, which Android
/// keeps alive *because the FG service exists*. The handler is here
/// only because the API insists on having one.
@pragma('vm:entry-point')
void sharerForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_SharerTaskHandler());
}

class _SharerTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    // ForegroundTaskEventAction.nothing() means this never fires; left
    // as a no-op for forward-compat in case we ever switch to a
    // periodic event action (e.g. a cheap heartbeat).
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    // User tapped the idle notification — bring the app forward.
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {}
}
