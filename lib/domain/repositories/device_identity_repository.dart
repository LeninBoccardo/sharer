import '../entities/device_identity.dart';

abstract class DeviceIdentityRepository {
  /// Loads the persistent identity, generating one on first call.
  Future<DeviceIdentity> get();

  Future<void> rename(String name);

  /// Sign [message] with the local device's long-term private key
  /// (Ed25519). Returns the 64-byte signature bytes. Used for pairing
  /// and any future identity-bearing operation; the file-transfer hot
  /// path stays on the per-pair PSK + HMAC.
  Future<List<int>> sign(List<int> message);
}
