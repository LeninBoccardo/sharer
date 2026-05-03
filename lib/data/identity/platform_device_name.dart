import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

/// Resolves a human-readable default device name per platform. Falls back
/// to the system hostname (then a generic string) if device_info_plus is
/// unavailable. Result is persisted on first call by [DeviceIdentityStore]
/// so renames stick.
Future<String> readPlatformDeviceName({DeviceInfoPlugin? plugin}) async {
  final info = plugin ?? DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      final brand = _capitalize(a.brand);
      final model = a.model.trim();
      if (model.isEmpty) return brand.isEmpty ? 'Android device' : brand;
      if (brand.isEmpty || model.toLowerCase().startsWith(brand.toLowerCase())) {
        return model;
      }
      return '$brand $model';
    }
    if (Platform.isIOS) {
      final ios = await info.iosInfo;
      final n = ios.name.trim();
      if (n.isNotEmpty) return n;
      return ios.utsname.machine;
    }
    if (Platform.isWindows) {
      return (await info.windowsInfo).computerName;
    }
    if (Platform.isMacOS) {
      return (await info.macOsInfo).computerName;
    }
    if (Platform.isLinux) {
      final l = await info.linuxInfo;
      return l.prettyName.isNotEmpty ? l.prettyName : l.name;
    }
  } catch (_) {
    // device_info_plus channel unavailable — fall through to hostname.
  }

  try {
    final host = Platform.localHostname;
    if (host.isNotEmpty && host.toLowerCase() != 'localhost') return host;
  } catch (_) {}

  return 'Sharer device';
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}
