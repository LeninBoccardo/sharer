import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_key_value_store.dart';
import 'tls_key_generator.dart';
import 'tls_key_material.dart';

/// Hook the store invokes once when fresh TLS material is generated
/// (first launch OR after a corruption-driven regen). The composition
/// root wires this to wipe paired devices, since every entry there
/// pinned the prior cert fingerprint and would now reject every
/// connection. Mirrors [DeviceIdentityStore]'s migration callback.
typedef OnTlsMaterialReset = Future<void> Function();

/// Lazy, single-instance store for the device's TLS keypair + cert.
/// First call generates fresh material and persists it; subsequent
/// calls return the same in-memory instance without touching storage.
///
/// The private key PEM lives in [SecureKeyValueStore] (Keystore /
/// DPAPI / Keychain); the cert PEM is in [SharedPreferences] because
/// it's public anyway and the secure store doesn't need to carry the
/// extra ~600-byte payload.
class TlsKeyMaterialStore {
  static const _logName = 'sharer.tls';

  static const _certKey = 'device.tls.cert.v1';
  static const _privateKeyKey = 'device.tls.key.v1';

  final SharedPreferences _prefs;
  final SecureKeyValueStore _secure;
  final OnTlsMaterialReset? _onReset;

  Future<TlsKeyMaterial>? _materialFuture;

  TlsKeyMaterialStore(
    this._prefs, {
    required SecureKeyValueStore secure,
    OnTlsMaterialReset? onReset,
  })  : _secure = secure,
        _onReset = onReset;

  /// Returns the current TLS key material, generating + persisting if
  /// none exists yet. Cached after the first call so [HttpFileServer]
  /// can call this every restart without paying for keygen twice.
  Future<TlsKeyMaterial> get() {
    return _materialFuture ??= _loadOrGenerate();
  }

  Future<TlsKeyMaterial> _loadOrGenerate() async {
    final certPem = _prefs.getString(_certKey);
    final keyPem = await _secure.read(_privateKeyKey);
    if (certPem != null &&
        keyPem != null &&
        certPem.contains('BEGIN CERTIFICATE') &&
        keyPem.contains('BEGIN EC PRIVATE KEY')) {
      try {
        final material = TlsKeyMaterial(
          certificatePem: certPem,
          privateKeyPem: keyPem,
        );
        // Force the fingerprint computation now so a corrupt/non-
        // matching pair fails here rather than at server-bind time.
        final fp = material.certificateFingerprintSha256;
        _log('loaded existing TLS material fingerprint=$fp');
        return material;
      } catch (e) {
        _log('stored TLS material is corrupt — regenerating: $e');
      }
    }

    final hadOldMaterial = certPem != null || keyPem != null;
    final fresh = TlsKeyGenerator.generate();
    await _prefs.setString(_certKey, fresh.certificatePem);
    await _secure.write(_privateKeyKey, fresh.privateKeyPem);

    if (hadOldMaterial) {
      _log('regenerated TLS material; wiping paired-devices store '
          '(stale cert fingerprints can no longer be verified)');
      final cb = _onReset;
      if (cb != null) {
        try {
          await cb();
        } catch (e, st) {
          developer.log('TLS material reset callback failed',
              error: e, stackTrace: st, name: _logName);
        }
      }
    }

    _log('generated fresh TLS material '
        'fingerprint=${fresh.certificateFingerprintSha256}');
    return fresh;
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
