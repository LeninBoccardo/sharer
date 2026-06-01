import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';

import '../../domain/entities/paired_device.dart';
import '../../domain/repositories/paired_devices_repository.dart';
import 'hmac_signer.dart';

/// Outcome of validating an inbound signed request. Sealed so the server
/// must handle every case explicitly — there is no silent fall-through.
sealed class HmacVerifyResult {
  const HmacVerifyResult();
}

/// Headers were present and valid; the request was made by [device].
class HmacAuthenticated extends HmacVerifyResult {
  final PairedDevice device;
  const HmacAuthenticated(this.device);
}

/// No HMAC headers were sent. Caller decides what to do — slice 4.2 falls
/// back to the existing trust-network gate; slice 4.3+ may reject outright.
class HmacUnsigned extends HmacVerifyResult {
  const HmacUnsigned();
}

/// Why an [HmacRejected] fired. The server maps these to distinct wire
/// responses: [unknownSender] means "the peer is not in our paired
/// store" — i.e. they don't recognize our identity/PSK — and is the
/// ONLY reason that should trigger the reactive-forget path on the
/// sender. Every [transient] reason (clock skew, nonce replay,
/// malformed/partial headers, signature mismatch from a *known* peer)
/// is a recoverable signing failure and must NOT unpair anyone.
enum HmacRejectionReason {
  /// The senderDeviceId has no matching PairedDevice. The peer forgot
  /// us (or never knew us). Server returns 403 + X-Sharer-Reason.
  unknownSender,

  /// Any recoverable signing failure: partial headers, malformed
  /// timestamp, timestamp out of window, nonce replay, malformed
  /// signature, or signature mismatch against a known peer's PSK.
  /// Server returns a bare 401.
  transient,
}

/// Headers were present but did not validate. Always reject. [detail] is
/// for logs only; do not echo it to the wire (the spec says don't leak
/// which check failed). [reason] is the coarse category the server uses
/// to pick the wire response.
class HmacRejected extends HmacVerifyResult {
  final String detail;
  final HmacRejectionReason reason;
  const HmacRejected(this.detail, this.reason);
}

/// Server-side validator for the X-Sharer-Sig family of headers.
///
/// Holds an in-memory replay buffer of recently-seen nonces. The buffer
/// is bounded by the nonce TTL (60 s by default) and purged on every
/// verify call. Per-instance, not static — tests get isolation, and
/// nothing leaks across server restarts.
class HmacVerifier {
  static const _logName = 'sharer.security.hmac';

  final PairedDevicesRepository _paired;
  final Duration _clockSkew;
  final Duration _nonceTtl;
  final DateTime Function() _now;

  final Map<String, DateTime> _seenNonces = {};

  HmacVerifier(
    this._paired, {
    Duration? clockSkew,
    Duration? nonceTtl,
    DateTime Function()? now,
  })  : _clockSkew = clockSkew ?? const Duration(seconds: 30),
        _nonceTtl = nonceTtl ?? const Duration(seconds: 60),
        _now = now ?? DateTime.now;

  /// Slice 5.4: the `/peer-forgot-you` handler reuses the same paired
  /// store to look up the sender's PSK. Exposing the repo here keeps
  /// the server from having to take a second injection of the same
  /// store.
  PairedDevicesRepository get repository => _paired;

  /// Slice 5.x.2.4: takes the [Request] directly and derives method+path
  /// from it. Previously these were caller-passed strings — only one
  /// caller (http_file_server.dart) used the verifier and hard-coded
  /// `'POST'` / `TransportProtocol.uploadPath`, but the API invited a
  /// future second caller to drift, which would let a peer's `/upload`
  /// signature replay against a different path.
  Future<HmacVerifyResult> verify({
    required Request request,
    required String? senderDeviceId,
    required String? timestamp,
    required String? nonce,
    required String? signature,
    required String filename,
    required int filesize,
    String? transferId,
  }) async {
    final method = request.method;
    final path = request.requestedUri.path;
    final hasAny = _present(timestamp) || _present(nonce) || _present(signature);
    if (!hasAny) return const HmacUnsigned();

    if (!_present(senderDeviceId) ||
        !_present(timestamp) ||
        !_present(nonce) ||
        !_present(signature)) {
      return _reject('partial signature headers', HmacRejectionReason.transient);
    }

    final device = await _paired.get(senderDeviceId!);
    if (device == null) {
      return _reject('unknown sender $senderDeviceId',
          HmacRejectionReason.unknownSender);
    }

    final ts = int.tryParse(timestamp!);
    if (ts == null) {
      return _reject('malformed timestamp', HmacRejectionReason.transient);
    }
    final ageMs = _now().toUtc().millisecondsSinceEpoch - ts;
    if (ageMs.abs() > _clockSkew.inMilliseconds) {
      return _reject('timestamp out of window (age=${ageMs}ms)',
          HmacRejectionReason.transient);
    }

    _purgeOldNonces();
    final replayKey = '$senderDeviceId|$nonce';
    if (_seenNonces.containsKey(replayKey)) {
      return _reject('nonce replay', HmacRejectionReason.transient);
    }

    final canonical = canonicalString(
      method: method,
      path: path,
      timestampMs: ts,
      nonce: nonce!,
      senderDeviceId: senderDeviceId,
      filename: filename,
      filesize: filesize,
      transferId: transferId,
    );
    final expected = Hmac(sha256, device.psk).convert(utf8.encode(canonical));
    final provided = _safeBase64Decode(signature!);
    if (provided == null) {
      return _reject('malformed signature', HmacRejectionReason.transient);
    }
    if (!_constantTimeEquals(expected.bytes, provided)) {
      return _reject('signature mismatch', HmacRejectionReason.transient);
    }

    _seenNonces[replayKey] = _now();
    return HmacAuthenticated(device);
  }

  static bool _present(String? s) => s != null && s.isNotEmpty;

  HmacRejected _reject(String detail, HmacRejectionReason reason) {
    developer.log('reject: $detail', name: _logName);
    debugPrint('[$_logName] reject: $detail');
    return HmacRejected(detail, reason);
  }

  void _purgeOldNonces() {
    final cutoff = _now().subtract(_nonceTtl);
    _seenNonces.removeWhere((_, when) => when.isBefore(cutoff));
  }

  static Uint8List? _safeBase64Decode(String s) {
    try {
      return Uint8List.fromList(base64Decode(s));
    } catch (_) {
      return null;
    }
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}
