import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/entities/file_payload.dart';
import '../security/hmac_signer.dart';
import '../security/pinning_http_client.dart';
import '../security/transfer_cipher.dart';
import 'transport_protocol.dart';

/// Result of a successful upload — what the receiver wrote.
class UploadResult {
  final String savedPath;
  final int bytesSent;
  const UploadResult({required this.savedPath, required this.bytesSent});
}

/// Slice 5.4: typed failure for a non-2xx upload response. The status
/// code lets the transfer layer take a status-specific action — a 401
/// from a known paired peer triggers the reactive forget path; other
/// codes just propagate as a regular failed transfer.
class UploadStatusException implements Exception {
  UploadStatusException({
    required this.statusCode,
    required this.body,
    required this.uri,
    this.reason,
  });
  final int statusCode;
  final String body;
  final Uri uri;

  /// Audit #1: the server's `X-Sharer-Reason` header, when present.
  /// `'unknown-sender'` on a 403 means the peer doesn't recognize us and
  /// the transfer layer should reactively forget them; null (e.g. on a
  /// bare 401) means a transient signing failure that must NOT unpair.
  final String? reason;

  @override
  String toString() => 'Upload failed: $statusCode ${body.isEmpty ? '' : body} '
      '${reason == null ? '' : 'reason=$reason '}(POST $uri)';
}

/// Audit #26: typed failure when the payload stream drains a different
/// number of plaintext bytes than [FilePayload.sizeBytes] promised.
///
/// `Content-Length` is computed up-front from `sizeBytes` (directly for
/// plaintext, via [encryptedLengthFor] for the encrypted path). If the
/// stream is short, the declared length never arrives and the request
/// stalls / writes a truncated file on the receiver; if it overruns, the
/// HTTP framing is corrupt. We detect the divergence the moment
/// [HttpClientRequest.addStream] returns — before awaiting `close()`, so
/// we never block on the never-arriving bytes — and fail the transfer
/// loudly instead of letting it hang or silently truncate.
class PayloadSizeMismatchException implements Exception {
  PayloadSizeMismatchException({
    required this.declaredBytes,
    required this.actualBytes,
    required this.fileName,
  });
  final int declaredBytes;
  final int actualBytes;
  final String fileName;

  @override
  String toString() =>
      'Payload size mismatch for "$fileName": declared $declaredBytes '
      'bytes but stream produced $actualBytes. Aborting to avoid a '
      'truncated/corrupt transfer.';
}

/// Slice 5.x.2.3: typed failure for a production (TLS) upload to a
/// paired peer whose entry has no `certFingerprint` (PairedDevice's doc
/// comment explicitly allows this for pre-TLS / pre-5.1 rows). Without
/// a pin we have no trust anchor — the alternative is accept-any-cert,
/// which is a silent MITM hole. Surfacing this lets the UI prompt the
/// user to re-pair instead of failing with an opaque TLS error.
class UnpinnedPeerException implements Exception {
  UnpinnedPeerException({required this.host, required this.port});
  final String host;
  final int port;

  @override
  String toString() => 'Refusing TLS upload to $host:$port — paired entry '
      'has no certificate fingerprint. Re-pair the device.';
}

/// Sending side of the file-transfer transport. Streams the payload in
/// a single chunked POST — never reads the whole file into memory.
///
/// **Slice 5.1 — TLS + cert pinning:** when [_overrideHttpClient] is
/// null (production), each [upload] call builds a fresh single-use
/// [HttpClient] that pins against the recipient's
/// [PairedDevice.certFingerprint]. Tests can opt out by passing an
/// explicit `httpClient: HttpClient()` to the constructor — that
/// path uses plain HTTP and skips pinning entirely.
class HttpFileClient {
  static const _logName = 'sharer.transport.client';

  /// When non-null, every upload uses this client and skips the
  /// pinning machinery — test convenience for plain-HTTP servers.
  final HttpClient? _overrideHttpClient;
  final HmacSigner _signer;

  HttpFileClient({HttpClient? httpClient, HmacSigner? signer})
      : _overrideHttpClient = httpClient,
        _signer = signer ?? HmacSigner();

  /// Streams [file] to the recipient. Production callers MUST pass
  /// [recipientCertFingerprint] — without it, the pinning client
  /// rejects every cert. Tests using a plain-HTTP server (constructed
  /// with an explicit `httpClient`) can leave it null.
  ///
  /// When [recipientPsk] is non-null, the request is HMAC-signed with
  /// X-Sharer-Timestamp / Nonce / Sig headers (slice 4.2). After slice
  /// 4.4 production servers reject unsigned uploads outright.
  ///
  /// [onProgress] is invoked with cumulative bytes sent.
  Future<UploadResult> upload({
    required String host,
    required int port,
    required FilePayload file,
    required DeviceIdentity sender,
    required String recipientDeviceId,
    Uint8List? recipientPsk,
    String? recipientCertFingerprint,
    void Function(int bytesSent)? onProgress,
  }) async {
    final useTls = _overrideHttpClient == null;
    final scheme = useTls ? 'https' : 'http';
    final uri =
        Uri.parse('$scheme://$host:$port${TransportProtocol.uploadPath}');

    // Slice 5.x.2.3: refuse TLS upload to a paired peer whose entry
    // carries no cert fingerprint — the alternative is reaching the
    // pinning client with both args null and crashing inside the
    // bad-certificate callback. Surfacing this as a typed exception
    // lets the UI prompt the user to re-pair.
    if (useTls && recipientCertFingerprint == null) {
      throw UnpinnedPeerException(host: host, port: port);
    }

    // Slice 5.3: when we have a PSK to sign with, we also encrypt every
    // chunk end-to-end. Unsigned uploads (test convenience only) stay
    // plaintext — production servers reject those at the HMAC gate
    // anyway, so the unencrypted code path never runs against a real
    // peer.
    final transferIdBytes =
        recipientPsk != null ? newTransferId() : null;
    final transferIdB64 =
        transferIdBytes != null ? base64Encode(transferIdBytes) : null;
    final encrypt = recipientPsk != null;
    final wireSize = encrypt
        ? encryptedLengthFor(file.sizeBytes)
        : file.sizeBytes;
    _log('POST $uri  file=${file.fileName} size=${file.sizeBytes}'
        ' signed=${recipientPsk != null}'
        ' pinned=${recipientCertFingerprint != null}'
        ' encrypted=$encrypt wireSize=$wireSize');

    final http = _overrideHttpClient ??
        buildPinningHttpClient(expectedFingerprint: recipientCertFingerprint);
    final ownsClient = _overrideHttpClient == null;

    try {
      final request = await http.postUrl(uri);
      request.headers.contentType = ContentType.parse(
        file.mimeType ?? 'application/octet-stream',
      );
      request.headers.contentLength = wireSize;
      request.headers.set(
        TransportProtocol.headerFileName,
        Uri.encodeComponent(file.fileName),
      );
      request.headers.set(
        TransportProtocol.headerFileSize,
        file.sizeBytes.toString(),
      );
      request.headers.set(TransportProtocol.headerDeviceId, sender.id);
      request.headers.set(
        TransportProtocol.headerDeviceName,
        Uri.encodeComponent(sender.name),
      );
      if (transferIdB64 != null) {
        request.headers
            .set(TransportProtocol.headerTransferId, transferIdB64);
      }

      if (recipientPsk != null) {
        final signed = _signer.sign(
          psk: recipientPsk,
          method: 'POST',
          path: TransportProtocol.uploadPath,
          senderDeviceId: sender.id,
          recipientDeviceId: recipientDeviceId,
          filename: file.fileName,
          filesize: file.sizeBytes,
          transferId: transferIdB64,
        );
        request.headers
            .set(TransportProtocol.headerTimestamp, signed.timestamp);
        request.headers.set(TransportProtocol.headerNonce, signed.nonce);
        request.headers
            .set(TransportProtocol.headerSignature, signed.signature);
      }

      // Track plaintext bytes for progress so the UI shows file-relative
      // progress, not wire bytes — encrypted overhead would be confusing.
      var bytesSent = 0;
      final tracked = file.bytes.map((chunk) {
        bytesSent += chunk.length;
        onProgress?.call(bytesSent);
        return chunk;
      });

      Stream<List<int>> wireStream = tracked;
      if (encrypt) {
        final cipher = await TransferCipher.derive(
          psk: recipientPsk,
          transferId: transferIdBytes!,
        );
        wireStream = cipher.encrypt(tracked);
      }

      await request.addStream(wireStream);

      // Audit #26: Content-Length was set from file.sizeBytes (via
      // wireSize). If the stream produced a different number of
      // plaintext bytes, the on-wire length no longer matches the
      // declared length: a short stream would leave request.close()
      // waiting for bytes that never come (the request hangs until the
      // owned pinning client is force-closed in finally) and the
      // receiver writes a truncated file; an overrun corrupts framing.
      // Detect the divergence here — before awaiting close() — and abort
      // with a typed error so the transfer fails fast instead of hanging
      // or silently truncating. addStream has fully drained file.bytes
      // by now, so bytesSent is final.
      if (bytesSent != file.sizeBytes) {
        throw PayloadSizeMismatchException(
          declaredBytes: file.sizeBytes,
          actualBytes: bytesSent,
          fileName: file.fileName,
        );
      }

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != HttpStatus.ok) {
        throw UploadStatusException(
          statusCode: response.statusCode,
          body: body,
          uri: uri,
          reason: response.headers.value(TransportProtocol.headerReason),
        );
      }

      String savedPath = '';
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        savedPath = json['savedPath'] as String? ?? '';
      } catch (_) {
        // Tolerate non-JSON success bodies.
      }

      _log('POST done bytesSent=$bytesSent savedPath=$savedPath');
      return UploadResult(savedPath: savedPath, bytesSent: bytesSent);
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  void close() {
    _overrideHttpClient?.close(force: true);
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
