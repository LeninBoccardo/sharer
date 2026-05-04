import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/entities/paired_device.dart';
import '../../domain/repositories/paired_devices_repository.dart';
import 'secure_key_value_store.dart';

/// Secure-storage-backed implementation of the paired devices repository.
///
/// Storage layout: one entry per paired device, keyed by
/// `paired_device:<deviceId>`. The value is a JSON object. The PSK is
/// base64-encoded so the JSON stays printable; secrecy comes from the
/// underlying SecureKeyValueStore, not from the encoding.
///
/// We hold an in-memory cache of the registry after first load so reads on
/// the share hot path don't await secure storage. The cache is rebuilt from
/// disk on each instance and kept in sync with every mutation.
class PairedDevicesStore implements PairedDevicesRepository {
  static const _keyPrefix = 'paired_device:';

  final SecureKeyValueStore _store;
  final StreamController<List<PairedDevice>> _controller =
      StreamController<List<PairedDevice>>.broadcast();

  Map<String, PairedDevice>? _cache;
  Future<Map<String, PairedDevice>>? _loading;

  PairedDevicesStore(this._store);

  @override
  Future<List<PairedDevice>> getAll() async {
    final cache = await _ensureLoaded();
    return cache.values.toList(growable: false);
  }

  @override
  Future<PairedDevice?> get(String deviceId) async {
    final cache = await _ensureLoaded();
    return cache[deviceId];
  }

  @override
  Future<void> add(PairedDevice device) async {
    final cache = await _ensureLoaded();
    await _store.write(_keyFor(device.deviceId), jsonEncode(_toJson(device)));
    cache[device.deviceId] = device;
    _emit(cache);
    _log(
      'paired device added: id=${device.deviceId} name=${device.displayName}',
    );
  }

  @override
  Future<void> remove(String deviceId) async {
    final cache = await _ensureLoaded();
    if (cache.remove(deviceId) == null) return;
    await _store.delete(_keyFor(deviceId));
    _emit(cache);
    _log('paired device removed: id=$deviceId');
  }

  @override
  Stream<List<PairedDevice>> watch() async* {
    final cache = await _ensureLoaded();
    yield cache.values.toList(growable: false);
    yield* _controller.stream;
  }

  Future<void> dispose() async {
    await _controller.close();
  }

  Future<Map<String, PairedDevice>> _ensureLoaded() async {
    final cached = _cache;
    if (cached != null) return cached;
    final loading = _loading ??= _load();
    final loaded = await loading;
    _cache ??= loaded;
    _loading = null;
    return _cache!;
  }

  Future<Map<String, PairedDevice>> _load() async {
    final all = await _store.readAll();
    final result = <String, PairedDevice>{};
    for (final entry in all.entries) {
      if (!entry.key.startsWith(_keyPrefix)) continue;
      try {
        final json = jsonDecode(entry.value) as Map<String, dynamic>;
        final dev = _fromJson(json);
        result[dev.deviceId] = dev;
      } catch (e) {
        // Corrupt entry — drop it rather than crash the app on launch.
        _log('dropping corrupt paired-device entry ${entry.key}: $e');
        await _store.delete(entry.key);
      }
    }
    return result;
  }

  void _emit(Map<String, PairedDevice> cache) {
    if (_controller.isClosed) return;
    _controller.add(cache.values.toList(growable: false));
  }

  static String _keyFor(String deviceId) => '$_keyPrefix$deviceId';

  static Map<String, dynamic> _toJson(PairedDevice d) => {
        'deviceId': d.deviceId,
        'displayName': d.displayName,
        'psk': base64Encode(d.psk),
        'publicKey': base64Encode(d.publicKey),
        if (d.certFingerprint != null) 'certFingerprint': d.certFingerprint,
        'pairedAt': d.pairedAt.toUtc().toIso8601String(),
      };

  static PairedDevice _fromJson(Map<String, dynamic> j) => PairedDevice(
        deviceId: j['deviceId'] as String,
        displayName: j['displayName'] as String,
        psk: Uint8List.fromList(base64Decode(j['psk'] as String)),
        publicKey:
            Uint8List.fromList(base64Decode(j['publicKey'] as String)),
        certFingerprint: j['certFingerprint'] as String?,
        pairedAt: DateTime.parse(j['pairedAt'] as String),
      );

  void _log(String message) {
    developer.log(message, name: 'sharer.security.paired');
    debugPrint('[paired] $message');
  }
}
