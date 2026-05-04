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
  final String? certFingerprint;
  final DateTime pairedAt;

  PairedDevice({
    required this.deviceId,
    required this.displayName,
    required this.psk,
    required this.pairedAt,
    this.certFingerprint,
  }) : assert(psk.length == 32, 'PSK must be 32 bytes (256 bits)');

  PairedDevice copyWith({
    String? displayName,
    Uint8List? psk,
    String? certFingerprint,
    DateTime? pairedAt,
  }) {
    return PairedDevice(
      deviceId: deviceId,
      displayName: displayName ?? this.displayName,
      psk: psk ?? this.psk,
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
    return true;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        displayName,
        certFingerprint,
        pairedAt,
        Object.hashAll(psk),
      );
}
