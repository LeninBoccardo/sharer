import 'package:shared_preferences/shared_preferences.dart';

/// Persistent set of "pinned" / favorite peer deviceIds. Favorited paired
/// peers sort to the top of the Paired section on the home screen. Mirrors
/// TrustedNetworksStore: a thin StringList wrapper with a synchronous load()
/// for instant seeding and async mutators.
class FavoritesStore {
  static const _key = 'peers.favorites.v1';

  final SharedPreferences _prefs;
  FavoritesStore(this._prefs);

  Set<String> load() => _prefs.getStringList(_key)?.toSet() ?? <String>{};

  Future<void> add(String deviceId) async {
    final set = load()..add(deviceId);
    await _prefs.setStringList(_key, set.toList());
  }

  Future<void> remove(String deviceId) async {
    final set = load()..remove(deviceId);
    await _prefs.setStringList(_key, set.toList());
  }

  /// Toggles membership and returns the new state (true = now favorite).
  Future<bool> toggle(String deviceId) async {
    final set = load();
    final nowFav = !set.contains(deviceId);
    if (nowFav) {
      set.add(deviceId);
    } else {
      set.remove(deviceId);
    }
    await _prefs.setStringList(_key, set.toList());
    return nowFav;
  }

  bool contains(String deviceId) => load().contains(deviceId);
}
