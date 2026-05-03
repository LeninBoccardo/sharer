import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/repositories/device_identity_repository.dart';

/// Resolves the human-readable default name for this device. Injected so
/// platform-coupled code (device_info_plus) stays out of the store and can
/// be swapped in tests.
typedef DefaultDeviceNameResolver = Future<String> Function();

class DeviceIdentityStore implements DeviceIdentityRepository {
  static const _idKey = 'device.identity.id';
  static const _nameKey = 'device.identity.name';

  final SharedPreferences _prefs;
  final Uuid _uuid;
  final DefaultDeviceNameResolver _defaultName;

  DeviceIdentity? _cached;

  DeviceIdentityStore(
    this._prefs, {
    Uuid? uuid,
    DefaultDeviceNameResolver? defaultName,
  })  : _uuid = uuid ?? const Uuid(),
        _defaultName = defaultName ?? _fallbackDefaultName;

  @override
  Future<DeviceIdentity> get() async {
    final cached = _cached;
    if (cached != null) return cached;

    var id = _prefs.getString(_idKey);
    if (id == null) {
      id = _uuid.v4();
      await _prefs.setString(_idKey, id);
    }

    var name = _prefs.getString(_nameKey);
    if (name == null) {
      name = await _defaultName();
      // Persist on first resolution so the name is stable across launches.
      await _prefs.setString(_nameKey, name);
    }

    final identity = DeviceIdentity(id: id, name: name);
    _cached = identity;
    return identity;
  }

  @override
  Future<void> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _prefs.setString(_nameKey, trimmed);
    final current = await get();
    _cached = DeviceIdentity(id: current.id, name: trimmed);
  }

  static Future<String> _fallbackDefaultName() async => 'Sharer device';
}
