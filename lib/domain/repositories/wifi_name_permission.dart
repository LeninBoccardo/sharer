/// State of the permission Sharer needs to resolve the current Wi-Fi
/// network's name (SSID).
enum WifiNamePermissionStatus {
  /// The OS will let us read the SSID. (Location *services* must also be on —
  /// a separate device toggle this permission grant does not cover.)
  granted,

  /// Denied, but the runtime dialog can be shown again.
  denied,

  /// Denied with "don't ask again" — only the app settings page can flip it.
  permanentlyDenied,

  /// No app-level runtime grant exists on this platform (desktop): the user
  /// must toggle the OS location setting manually.
  unsupported,
}

/// Reads/requests the permission that gates reading the current Wi-Fi
/// network's name (SSID).
///
/// On Android/iOS the SSID is gated behind the location permission, which has
/// a real runtime dialog. On desktop there is no app-level grant — only an OS
/// settings toggle the user flips manually — so [supportsRuntimeRequest] is
/// false and [request] deep-links to settings instead of prompting.
///
/// Abstracted (rather than calling permission_handler inline) so the
/// presentation layer stays platform-channel-free and the banner/diagnostics
/// flows are widget-testable against a fake.
abstract class WifiNamePermission {
  /// Whether [request] can pop a runtime dialog (Android/iOS) vs. only
  /// deep-linking to OS settings (desktop).
  bool get supportsRuntimeRequest;

  /// Best-effort current grant state. Returns [WifiNamePermissionStatus.unsupported]
  /// on desktop.
  Future<WifiNamePermissionStatus> status();

  /// Ask for the grant. Android/iOS pop the system dialog; desktop opens the
  /// OS location settings and returns [WifiNamePermissionStatus.unsupported].
  Future<WifiNamePermissionStatus> request();

  /// Deep-link to where the user can flip the setting: the app's settings
  /// page (Android, when permanently denied) or the OS location settings
  /// (desktop).
  Future<void> openSettings();
}
