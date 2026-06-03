import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:url_launcher/url_launcher.dart';

import '../../domain/repositories/wifi_name_permission.dart';

/// Android/iOS impl: reading the SSID is gated behind the foreground location
/// permission. Backed by permission_handler.
class LocationWifiNamePermission implements WifiNamePermission {
  const LocationWifiNamePermission();

  @override
  bool get supportsRuntimeRequest => true;

  @override
  Future<WifiNamePermissionStatus> status() =>
      _map(ph.Permission.locationWhenInUse.status);

  @override
  Future<WifiNamePermissionStatus> request() =>
      _map(ph.Permission.locationWhenInUse.request());

  @override
  Future<void> openSettings() async {
    await ph.openAppSettings();
  }

  Future<WifiNamePermissionStatus> _map(Future<ph.PermissionStatus> future) async {
    final status = await future;
    if (status.isGranted || status.isLimited) {
      return WifiNamePermissionStatus.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return WifiNamePermissionStatus.permanentlyDenied;
    }
    return WifiNamePermissionStatus.denied;
  }
}

/// Desktop impl: there is no app-level location grant to request. On Windows
/// the SSID read is gated behind the OS Location privacy setting, so we
/// deep-link to it (`ms-settings:privacy-location`). macOS/Linux have no
/// universal deep link — the banner copy tells the user where to look.
class DesktopWifiNamePermission implements WifiNamePermission {
  const DesktopWifiNamePermission();

  @override
  bool get supportsRuntimeRequest => false;

  @override
  Future<WifiNamePermissionStatus> status() async =>
      WifiNamePermissionStatus.unsupported;

  @override
  Future<WifiNamePermissionStatus> request() async {
    await openSettings();
    return WifiNamePermissionStatus.unsupported;
  }

  @override
  Future<void> openSettings() async {
    if (!kIsWeb && Platform.isWindows) {
      final uri = Uri.parse('ms-settings:privacy-location');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    }
  }
}
