import 'package:screen_brightness/screen_brightness.dart';

/// Drives display brightness for the pairing-code screen. Abstracted (same
/// posture as ForegroundServiceGateway) so the screen can be widget-tested
/// against a fake instead of the real platform plugin. All methods are
/// best-effort: on hardware without programmatic brightness control the
/// plugin throws, which we swallow to a no-op so the pairing UI never breaks
/// over a backlight.
abstract class BrightnessController {
  /// Force this app's window brightness to maximum (1.0). On Android this is
  /// WindowManager.LayoutParams.screenBrightness — it does NOT change the
  /// system brightness and needs no permission.
  Future<void> boostToMax();

  /// Restore the previous/system brightness. Idempotent: safe to call even
  /// if [boostToMax] never ran or already restored.
  Future<void> restore();
}

class ScreenBrightnessController implements BrightnessController {
  final _screen = ScreenBrightness();
  bool _boosted = false;

  @override
  Future<void> boostToMax() async {
    try {
      // Application brightness affects only this app's window and is
      // auto-reverted by the OS on focus loss / app kill — a second safety
      // net behind our own restore().
      await _screen.setApplicationScreenBrightness(1.0);
      _boosted = true;
    } catch (_) {
      // Unsupported hardware / a desktop monitor that doesn't expose
      // brightness — silently degrade. The QR still renders.
    }
  }

  @override
  Future<void> restore() async {
    if (!_boosted) return;
    _boosted = false;
    try {
      await _screen.resetApplicationScreenBrightness();
    } catch (_) {/* no-op on unsupported platforms */}
  }
}
