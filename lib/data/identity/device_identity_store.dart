import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/repositories/device_identity_repository.dart';

class DeviceIdentityStore implements DeviceIdentityRepository {
  static const _idKey = 'device.identity.id';
  static const _nameKey = 'device.identity.name';

  final SharedPreferences _prefs;
  final Uuid _uuid;

  DeviceIdentity? _cached;

  DeviceIdentityStore(this._prefs, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  @override
  Future<DeviceIdentity> get() async {
    final cached = _cached;
    if (cached != null) return cached;

    var id = _prefs.getString(_idKey);
    if (id == null) {
      id = _uuid.v4();
      await _prefs.setString(_idKey, id);
    }

    final name = _prefs.getString(_nameKey) ?? _defaultName();
    final identity = DeviceIdentity(id: id, name: name);
    _cached = identity;
    return identity;
  }

  @override
  Future<void> rename(String name) async {
    await _prefs.setString(_nameKey, name);
    final current = await get();
    _cached = DeviceIdentity(id: current.id, name: name);
  }

  String _defaultName() {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty && host != 'localhost') return host;
    } catch (_) {
      // Platform.localHostname can throw on web / restricted environments.
    }
    return 'Sharer device';
  }
}
