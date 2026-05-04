import 'dart:typed_data';

/// The local device's identity. Per slice 4.5, [id] is the SHA-256
/// fingerprint of [publicKey] (16 hex chars). [publicKey] is the raw
/// 32-byte Ed25519 public key — embedded in pair offers and pinned by
/// peers during pairing so they can verify identity-bearing signatures
/// from this device on subsequent operations.
///
/// The matching private key never appears in this entity. Signing flows
/// through `DeviceIdentityRepository.sign(...)` so the private key stays
/// inside the store / signer pair.
class DeviceIdentity {
  final String id;
  final String name;
  final Uint8List publicKey;

  DeviceIdentity({
    required this.id,
    required this.name,
    required this.publicKey,
  }) : assert(publicKey.length == 32,
            'Ed25519 public key must be 32 bytes');

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DeviceIdentity) return false;
    if (id != other.id || name != other.name) return false;
    if (publicKey.length != other.publicKey.length) return false;
    for (var i = 0; i < publicKey.length; i++) {
      if (publicKey[i] != other.publicKey[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(publicKey));
}
