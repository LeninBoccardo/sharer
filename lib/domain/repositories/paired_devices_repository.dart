import '../entities/paired_device.dart';

/// Persistent registry of paired peers. The PSK and (later) cert fingerprint
/// are sensitive — implementations must back this with secret-grade storage
/// (Keystore / DPAPI / Keychain), not plain preferences.
abstract class PairedDevicesRepository {
  Future<List<PairedDevice>> getAll();

  Future<PairedDevice?> get(String deviceId);

  /// Insert or replace by deviceId.
  Future<void> add(PairedDevice device);

  Future<void> remove(String deviceId);

  /// Reactive view. Emits the current list on subscribe, then on every change.
  Stream<List<PairedDevice>> watch();
}
