import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Headers attached to a signed request, beyond the existing
/// X-Sharer-DeviceId / X-Sharer-DeviceName / X-Sharer-FileName /
/// X-Sharer-FileSize manifest. These are what the receiver feeds into
/// [HmacVerifier].
class SignedRequestHeaders {
  final String timestamp;
  final String nonce;
  final String signature;

  const SignedRequestHeaders({
    required this.timestamp,
    required this.nonce,
    required this.signature,
  });
}

/// Builds the X-Sharer-Sig family of headers for v1's HMAC layer.
///
/// **Note on body hashing (intentional omission — audit #48).** The literal
/// v1 spec calls for sha256(body) in the canonical string. We deliberately
/// leave it out:
///   1. Files stream end-to-end and may be multi-GB, so we cannot buffer the
///      body to hash it (architecture's "Streaming and memory" rule).
///   2. Body integrity does not need the HMAC. Since slice 5.3 the file body
///      is shipped as AES-256-GCM frames (see [TransferCipher] in
///      `transfer_cipher.dart`); each chunk carries a 16-byte GCM auth tag,
///      so any tampering with the bytes-on-wire fails decryption and aborts
///      the transfer. The per-transfer GCM key/nonce are derived from the
///      PSK + transferId, and the transferId itself IS an authenticated
///      field of this HMAC (the trailing field of [canonicalString]) — so
///      the HMAC binds the request to exactly the GCM stream that will follow.
/// The HMAC therefore authenticates the request manifest — sender, filename,
/// size, path, transferId — which gates "who can upload to this server" and
/// pins the GCM stream; per-chunk GCM tags (plus TLS + cert pinning) cover
/// the body bytes themselves. sha256(body) would be redundant.
class HmacSigner {
  final Random _random;
  final DateTime Function() _now;

  HmacSigner({Random? random, DateTime Function()? now})
      : _random = random ?? Random.secure(),
        _now = now ?? DateTime.now;

  SignedRequestHeaders sign({
    required Uint8List psk,
    required String method,
    required String path,
    required String senderDeviceId,
    required String recipientDeviceId,
    required String filename,
    required int filesize,
    String? transferId,
  }) {
    final timestampMs = _now().toUtc().millisecondsSinceEpoch;
    final nonce = _generateNonce();
    final canonical = canonicalString(
      method: method,
      path: path,
      timestampMs: timestampMs,
      nonce: nonce,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      filename: filename,
      filesize: filesize,
      transferId: transferId,
    );
    final mac = Hmac(sha256, psk).convert(utf8.encode(canonical));
    return SignedRequestHeaders(
      timestamp: timestampMs.toString(),
      nonce: nonce,
      signature: base64Encode(mac.bytes),
    );
  }

  String _generateNonce() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64Encode(bytes);
  }
}

/// Canonical input to HMAC-SHA256. Newline-delimited fields. Filename is
/// hashed so the field is fixed length and can't sneak in a delimiter.
///
/// Audit #30: [recipientDeviceId] — the local deviceId of the device the
/// request is destined for — is authenticated as a fixed field. The
/// sender supplies the recipient's id (the PairedDevice.deviceId it sends
/// to); the verifier reconstructs the canonical with its OWN local
/// deviceId. A signature minted for one recipient therefore can't be
/// replayed against a different device that shares the same per-pair PSK.
/// Defense-in-depth on top of the PSK lookup. WIRE-BREAKING: both ends
/// must include it; an old-format request fails the signature check and
/// is rejected (the safe default — see HmacVerifier.verify).
///
/// [transferId] (slice 5.3) appends a trailing field when non-null. It
/// stays the LAST field so the recipient-id addition doesn't disturb the
/// optional-transferId tail. The receiver mirrors whichever transferId
/// shape the request has on the wire — see `HttpFileServer._handleUpload`.
String canonicalString({
  required String method,
  required String path,
  required int timestampMs,
  required String nonce,
  required String senderDeviceId,
  required String recipientDeviceId,
  required String filename,
  required int filesize,
  String? transferId,
}) {
  final filenameHash = sha256.convert(utf8.encode(filename)).toString();
  final fields = [
    method.toUpperCase(),
    path,
    timestampMs.toString(),
    nonce,
    senderDeviceId,
    recipientDeviceId,
    filenameHash,
    filesize.toString(),
  ];
  if (transferId != null) fields.add(transferId);
  return fields.join('\n');
}
