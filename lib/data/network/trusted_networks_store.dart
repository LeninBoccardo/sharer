import 'package:shared_preferences/shared_preferences.dart';

class TrustedNetworksStore {
  static const _key = 'network.trusted_fingerprints';

  final SharedPreferences _prefs;

  TrustedNetworksStore(this._prefs);

  Set<String> load() => _prefs.getStringList(_key)?.toSet() ?? <String>{};

  Future<void> add(String fingerprint) async {
    final set = load()..add(fingerprint);
    await _prefs.setStringList(_key, set.toList());
  }

  Future<void> remove(String fingerprint) async {
    final set = load()..remove(fingerprint);
    await _prefs.setStringList(_key, set.toList());
  }

  bool contains(String fingerprint) => load().contains(fingerprint);
}
