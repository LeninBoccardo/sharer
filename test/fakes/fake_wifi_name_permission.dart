import 'package:sharer/domain/repositories/wifi_name_permission.dart';

/// Records request/openSettings calls and returns a canned status so the
/// banner + diagnostics flows can be widget-tested without a platform channel.
class FakeWifiNamePermission implements WifiNamePermission {
  FakeWifiNamePermission({
    this.supportsRuntimeRequest = true,
    this.requestResult = WifiNamePermissionStatus.granted,
    this.currentStatus = WifiNamePermissionStatus.denied,
  });

  @override
  final bool supportsRuntimeRequest;

  /// What [request] resolves to.
  WifiNamePermissionStatus requestResult;
  WifiNamePermissionStatus currentStatus;

  int requestCount = 0;
  int openSettingsCount = 0;

  @override
  Future<WifiNamePermissionStatus> status() async => currentStatus;

  @override
  Future<WifiNamePermissionStatus> request() async {
    requestCount++;
    return requestResult;
  }

  @override
  Future<void> openSettings() async {
    openSettingsCount++;
  }
}
