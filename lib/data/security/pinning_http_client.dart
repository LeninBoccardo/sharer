import 'dart:io';

import 'tls_key_material.dart';

/// Callback the TOFU client invokes when it accepts a cert that has
/// no prior pin (first-contact pair flows). Caller persists the
/// captured fingerprint as part of completing the pair so subsequent
/// transfers can pin against it.
typedef TofuSink = void Function(
  String host,
  int port,
  String fingerprintSha256,
);

/// Builds a single-use [HttpClient] that:
///
///   - Trusts no system roots — every peer is self-signed; the
///     fingerprint we pinned at pair time is the only trust anchor.
///   - **Pin mode** ([expectedFingerprint] non-null): accepts the
///     handshake iff the server cert's SHA-256 fingerprint matches.
///   - **TOFU mode** ([tofuSink] non-null, [expectedFingerprint] null):
///     accepts any cert and reports its fingerprint to the sink so
///     the caller can persist it as part of completing a pair. Used
///     ONLY on /pair-invite and /pair where we don't yet have a
///     fingerprint and the user is about to confirm via the 6-digit
///     verify code.
///
/// One client per request — the bad-certificate callback is bound to
/// per-request state, so reusing a client across requests would race
/// the pin. Caller MUST close the returned client after use.
HttpClient buildPinningHttpClient({
  String? expectedFingerprint,
  TofuSink? tofuSink,
}) {
  assert(expectedFingerprint != null || tofuSink != null,
      'buildPinningHttpClient needs either a pin or a TOFU sink — '
      'otherwise no cert can ever be accepted');

  final ctx = SecurityContext(withTrustedRoots: false);
  final client = HttpClient(context: ctx);
  client.badCertificateCallback = (cert, host, port) {
    final fingerprint = sha256FingerprintOfDer(cert.der);
    final pin = expectedFingerprint;
    if (pin != null) {
      final ok = _equalsIgnoreCase(pin, fingerprint);
      if (!ok) {
        // Surface the mismatch on stderr so a real-device test can
        // tell why a pinned request hung up. Most often this fires
        // when a peer regenerated their TLS material — re-pair fixes.
        stderr.writeln('[sharer.tls] reject cert from $host:$port — '
            'expected $pin, got $fingerprint');
      }
      return ok;
    }
    // TOFU branch — caller is in a first-contact pair flow. Capture
    // the fingerprint and accept; the user's 6-digit verify confirms
    // this is the right peer before the pair commits.
    tofuSink!.call(host, port, fingerprint);
    return true;
  };
  return client;
}

bool _equalsIgnoreCase(String a, String b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(i);
    if (ca == cb) continue;
    if (_toLower(ca) != _toLower(cb)) return false;
  }
  return true;
}

int _toLower(int c) => (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c;
