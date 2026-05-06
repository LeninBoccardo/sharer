import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

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

/// Headers were present but did not validate. Always reject. [reason] is
/// for logs only; do not echo it to the wire (the spec says don't leak
/// which check failed).
class HmacRejected extends HmacVerifyResult {
  final String reason;
  const HmacRejected(this.reason);
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

  Future<HmacVerifyResult> verify({
    required String method,
    required String path,
    required String? senderDeviceId,
    required String? timestamp,
    required String? nonce,
    required String? signature,
    required String filename,
    required int filesize,
    String? transferId,
  }) async {
    final hasAny = _present(timestamp) || _present(nonce) || _present(signature);
    if (!hasAny) return const HmacUnsigned();

    if (!_present(senderDeviceId) ||
        !_present(timestamp) ||
        !_present(nonce) ||
        !_present(signature)) {
      return _reject('partial signature headers');
    }

    final device = await _paired.get(senderDeviceId!);
    if (device == null) return _reject('unknown sender $senderDeviceId');

    final ts = int.tryParse(timestamp!);
    if (ts == null) return _reject('malformed timestamp');
    final ageMs = _now().toUtc().millisecondsSinceEpoch - ts;
    if (ageMs.abs() > _clockSkew.inMilliseconds) {
      return _reject('timestamp out of window (age=${ageMs}ms)');
    }

    _purgeOldNonces();
    final replayKey = '$senderDeviceId|$nonce';
    if (_seenNonces.containsKey(replayKey)) {
      return _reject('nonce replay');
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
    if (provided == null) return _reject('malformed signature');
    if (!_constantTimeEquals(expected.bytes, provided)) {
      return _reject('signature mismatch');
    }

    _seenNonces[replayKey] = _now();
    return HmacAuthenticated(device);
  }

  static bool _present(String? s) => s != null && s.isNotEmpty;

  HmacRejected _reject(String reason) {
    developer.log('reject: $reason', name: _logName);
    debugPrint('[$_logName] reject: $reason');
    return HmacRejected(reason);
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
