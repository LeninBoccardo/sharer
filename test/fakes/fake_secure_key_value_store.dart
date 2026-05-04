import 'package:sharer/data/security/secure_key_value_store.dart';

/// In-memory SecureKeyValueStore for unit tests. No platform channels, no
/// async surprises beyond what the real adapter exposes.
class FakeSecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _data = {};

  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.from(_data);
}
