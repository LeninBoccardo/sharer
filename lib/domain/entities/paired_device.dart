import 'dart:typed_data';

/// A peer that has completed pairing with this device. Pairing is the trust
/// boundary — the watcher's network gate is just a discoverability control.
///
/// The PSK is the 256-bit pre-shared key used to sign every HTTP request
/// between the two devices (X-Sharer-Sig / HMAC-SHA256). The certFingerprint
/// is exchanged at pair time so slice 5 can pin TLS without a re-pair; until
/// then it may be null on entries created against pre-TLS builds.
class PairedDevice {
  final String deviceId;
  final String displayName;
  final Uint8List psk;

  /// Peer's long-term Ed25519 public key, raw 32 bytes (slice 4.5).
  /// Pinned at pair time. Used to verify identity-bearing signatures
  /// from this peer on subsequent operations (currently the pair-
  /// completion handshake; future LAN-invite re-pair, etc.).
  final Uint8List publicKey;

  final String? certFingerprint;
  final DateTime pairedAt;

  PairedDevice({
    required this.deviceId,
    required this.displayName,
    required this.psk,
    required this.publicKey,
    required this.pairedAt,
    this.certFingerprint,
  })  : assert(psk.length == 32, 'PSK must be 32 bytes (256 bits)'),
        assert(publicKey.length == 32, 'publicKey must be 32 bytes');

  PairedDevice copyWith({
    String? displayName,
    Uint8List? psk,
    Uint8List? publicKey,
    String? certFingerprint,
    DateTime? pairedAt,
  }) {
    return PairedDevice(
      deviceId: deviceId,
      displayName: displayName ?? this.displayName,
      psk: psk ?? this.psk,
      publicKey: publicKey ?? this.publicKey,
      certFingerprint: certFingerprint ?? this.certFingerprint,
      pairedAt: pairedAt ?? this.pairedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PairedDevice) return false;
    if (deviceId != other.deviceId) return false;
    if (displayName != other.displayName) return false;
    if (certFingerprint != other.certFingerprint) return false;
    if (pairedAt != other.pairedAt) return false;
    if (psk.length != other.psk.length) return false;
    for (var i = 0; i < psk.length; i++) {
      if (psk[i] != other.psk[i]) return false;
    }
    if (publicKey.length != other.publicKey.length) return false;
    for (var i = 0; i < publicKey.length; i++) {
      if (publicKey[i] != other.publicKey[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        displayName,
        certFingerprint,
        pairedAt,
        Object.hashAll(psk),
        Object.hashAll(publicKey),
      );
}
