import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key/value contract over secret-grade storage. Lets the
/// PairedDevicesStore (and slice 5's cert/key store) be unit-tested with
/// an in-memory fake instead of mocking the flutter_secure_storage platform
/// channel. Mirrors the MdnsBackend / NetworkSource / DownloadsLocator
/// pattern used elsewhere in `data/`.
abstract class SecureKeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// Returns every key/value currently stored. Callers filter by prefix
  /// to scope to their domain (e.g. `paired_device:`).
  Future<Map<String, String>> readAll();
}

/// Production adapter over `flutter_secure_storage`. Default options use
/// each platform's strongest available backing — Keystore-backed custom
/// ciphers on Android (the old EncryptedSharedPreferences path was
/// deprecated by Google's Jetpack Security library and dropped in
/// flutter_secure_storage 10); DPAPI on Windows; Keychain on iOS/macOS.
class FlutterSecureStorageAdapter implements SecureKeyValueStore {
  final FlutterSecureStorage _storage;

  FlutterSecureStorageAdapter([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}
