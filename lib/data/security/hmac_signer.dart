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
/// **Note on body hashing.** The literal v1 spec calls for sha256(body) in
/// the canonical string. Files stream end-to-end and may be multi-GB, so
/// we cannot buffer the body to hash it (architecture's "Streaming and
/// memory" rule). We instead authenticate the request manifest — sender,
/// filename, size, path — which is sufficient to gate "who can upload to
/// this server". Bytes-on-wire integrity is layered on by TLS + cert
/// pinning in slice 5.
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
/// [transferId] (slice 5.3) appends an 8th field when non-null. Older
/// pre-5.3 signed requests omit it entirely so the canonical string
/// stays exactly 7 lines and existing pairs that haven't upgraded both
/// sides can still verify each other. The receiver mirrors whichever
/// shape the request has on the wire — see `HttpFileServer._handleUpload`.
String canonicalString({
  required String method,
  required String path,
  required int timestampMs,
  required String nonce,
  required String senderDeviceId,
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
    filenameHash,
    filesize.toString(),
  ];
  if (transferId != null) fields.add(transferId);
  return fields.join('\n');
}
