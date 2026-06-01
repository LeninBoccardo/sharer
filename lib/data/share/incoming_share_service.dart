import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One file delivered through the OS share-sheet (Android `ACTION_SEND`
/// today; Windows Share contract is deferred — see [start]).
class IncomingSharedFile {
  const IncomingSharedFile({
    required this.path,
    required this.name,
    required this.size,
    this.mimeType,
  });

  final String path;
  final String name;
  final int size;
  final String? mimeType;
}

/// Slice 5.5: bridges the platform share-sheet into Dart.
///
/// **Android**: a custom MethodChannel + EventChannel pair owned by
/// `MainActivity.kt`. The activity writes shared content:// URIs to
/// the app's cacheDir before handing them off so Dart can read them
/// with plain `dart:io`. Two delivery paths:
///
///   - [consumeInitial] returns the share that triggered a cold-start
///     launch; called once at boot before listening to [shares].
///   - [shares] emits a list of files for every subsequent share that
///     arrives via `onNewIntent` while the app is running.
///
/// **Windows**: not yet wired. The Windows Share contract requires
/// MSIX packaging + an appxmanifest declaring the share target — too
/// much packaging churn for one slice. Tracked as a 5.5.x follow-up.
/// On Windows / iOS / Linux this service is a no-op, [shares] never
/// emits, and [consumeInitial] returns null.
class IncomingShareService {
  static const _logName = 'sharer.share';
  static const _methodChannel = MethodChannel('sharer.share/methods');
  static const _eventChannel = EventChannel('sharer.share/events');

  IncomingShareService({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _methodChannelOverride = methodChannel,
        _eventChannelOverride = eventChannel;

  final MethodChannel? _methodChannelOverride;
  final EventChannel? _eventChannelOverride;

  final _shares = StreamController<List<IncomingSharedFile>>.broadcast();
  Stream<List<IncomingSharedFile>> get shares => _shares.stream;

  StreamSubscription<dynamic>? _eventSub;

  void start() {
    if (!_isPlatformSupported()) return;
    final channel = _eventChannelOverride ?? _eventChannel;
    _eventSub = channel.receiveBroadcastStream().listen(
      (raw) {
        final parsed = _parse(raw);
        if (parsed == null || parsed.isEmpty) return;
        _log('received ${parsed.length} share(s) via event channel');
        _shares.add(parsed);
      },
      onError: (Object e, StackTrace st) {
        developer.log('share event channel error',
            error: e, stackTrace: st, name: _logName);
      },
    );
    _log('start (event channel listening)');
  }

  /// Read the cold-start share. Idempotent — the platform side returns
  /// null on the second call. Returns null on platforms without
  /// share-sheet integration.
  Future<List<IncomingSharedFile>?> consumeInitial() async {
    if (!_isPlatformSupported()) return null;
    try {
      final channel = _methodChannelOverride ?? _methodChannel;
      final raw = await channel.invokeMethod<List<dynamic>?>('getInitialShare');
      final parsed = _parse(raw);
      if (parsed != null && parsed.isNotEmpty) {
        _log('consumeInitial: ${parsed.length} file(s)');
      }
      return parsed;
    } catch (e, st) {
      developer.log('consumeInitial failed',
          error: e, stackTrace: st, name: _logName);
      return null;
    }
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _shares.close();
  }

  bool _isPlatformSupported() {
    // The MethodChannel only exists on Android (MainActivity is the
    // Android-only entry point). Calling invokeMethod on other
    // platforms would throw MissingPluginException; cheaper to
    // short-circuit here. On Flutter web there is no dart:io, so reading
    // Platform.isAndroid throws UnsupportedError — kIsWeb is a
    // compile-time constant that short-circuits before that read (audit
    // #7). On native, kIsWeb==false folds this back to Platform.isAndroid.
    return !kIsWeb && Platform.isAndroid;
  }

  static List<IncomingSharedFile>? _parse(dynamic raw) {
    if (raw is! List) return null;
    final out = <IncomingSharedFile>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final m = entry.cast<dynamic, dynamic>();
      final path = m['path'];
      final name = m['name'];
      final size = m['size'];
      if (path is! String || name is! String) continue;
      out.add(IncomingSharedFile(
        path: path,
        name: name,
        size: size is num ? size.toInt() : 0,
        mimeType: m['mimeType'] is String ? m['mimeType'] as String : null,
      ));
    }
    return out;
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
