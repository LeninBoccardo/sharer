import '../entities/device_identity.dart';

abstract class DeviceIdentityRepository {
  /// Loads the persistent identity, generating one on first call.
  Future<DeviceIdentity> get();

  Future<void> rename(String name);
}
