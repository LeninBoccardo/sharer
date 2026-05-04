import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../security/long_term_signer.dart';
import '../security/secure_key_value_store.dart';

/// Resolves the human-readable default name for this device. Injected so
/// platform-coupled code (device_info_plus) stays out of the store and can
/// be swapped in tests.
typedef DefaultDeviceNameResolver = Future<String> Function();

/// Hook the store invokes once per migration from the slice 4.1–4.4
/// UUID-based identity to the slice 4.5 Ed25519 identity. The composition
/// root wires this to wipe the paired-devices store, since every entry
/// there was bound to the old deviceId / PSK that no longer match
/// anything.
typedef OnIdentityMigrationReset = Future<void> Function();

class DeviceIdentityStore implements DeviceIdentityRepository {
  static const _logName = 'sharer.identity';

  // Slice 4.5 layout.
  static const _seedKey = 'device.identity.seed.v2'; // base64 32-byte seed
  static const _publicKeyKey = 'device.identity.publickey.v2'; // base64 32 bytes
  static const _nameKey = 'device.identity.name';

  // Slice 4.1–4.4 keys, deleted on migration.
  static const _legacyIdKey = 'device.identity.id';

  final SharedPreferences _prefs;
  final SecureKeyValueStore _secure;
  final DefaultDeviceNameResolver _defaultName;
  final OnIdentityMigrationReset? _onMigrationReset;

  DeviceIdentity? _cachedIdentity;
  Future<LongTermSigner>? _signerFuture;

  DeviceIdentityStore(
    this._prefs, {
    required SecureKeyValueStore secure,
    DefaultDeviceNameResolver? defaultName,
    OnIdentityMigrationReset? onMigrationReset,
  })  : _secure = secure,
        _defaultName = defaultName ?? _fallbackDefaultName,
        _onMigrationReset = onMigrationReset;

  @override
  Future<DeviceIdentity> get() async {
    final cached = _cachedIdentity;
    if (cached != null) return cached;

    final signer = await _ensureSigner();
    var name = _prefs.getString(_nameKey);
    if (name == null) {
      name = await _defaultName();
      await _prefs.setString(_nameKey, name);
    }
    final identity = DeviceIdentity(
      id: signer.deviceIdFingerprint,
      name: name,
      publicKey: signer.publicKey,
    );
    _cachedIdentity = identity;
    return identity;
  }

  @override
  Future<void> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _prefs.setString(_nameKey, trimmed);
    final current = await get();
    _cachedIdentity = DeviceIdentity(
      id: current.id,
      name: trimmed,
      publicKey: current.publicKey,
    );
  }

  @override
  Future<List<int>> sign(List<int> message) async {
    final signer = await _ensureSigner();
    return signer.sign(message);
  }

  Future<LongTermSigner> _ensureSigner() {
    return _signerFuture ??= _loadOrGenerate();
  }

  Future<LongTermSigner> _loadOrGenerate() async {
    final existingSeed = await _secure.read(_seedKey);
    if (existingSeed != null && existingSeed.isNotEmpty) {
      try {
        final seed = base64Decode(existingSeed);
        final signer = await LongTermSigner.fromSeed(seed);
        _log('loaded existing identity fingerprint=${signer.deviceIdFingerprint}');
        return signer;
      } catch (e) {
        _log('stored seed is corrupt — regenerating: $e');
      }
    }

    // First launch (or post-migration / corruption recovery).
    final hadLegacyIdentity = _prefs.containsKey(_legacyIdKey);

    final fresh = await LongTermSigner.generate();
    final seedBytes = await fresh.extractSeed();
    await _secure.write(_seedKey, base64Encode(seedBytes));
    await _prefs.setString(_publicKeyKey, base64Encode(fresh.publicKey));

    if (hadLegacyIdentity) {
      await _prefs.remove(_legacyIdKey);
      _log('migrated from UUID identity to Ed25519; '
          'wiping paired-devices store');
      final cb = _onMigrationReset;
      if (cb != null) {
        try {
          await cb();
        } catch (e, st) {
          developer.log('migration reset callback failed',
              error: e, stackTrace: st, name: _logName);
        }
      }
    }

    _log('generated fresh identity fingerprint=${fresh.deviceIdFingerprint}');
    return fresh;
  }

  static Future<String> _fallbackDefaultName() async => 'Sharer device';

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
