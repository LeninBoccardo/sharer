import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/entities/file_payload.dart';
import '../security/hmac_signer.dart';
import 'transport_protocol.dart';

/// Result of a successful upload — what the receiver wrote.
class UploadResult {
  final String savedPath;
  final int bytesSent;
  const UploadResult({required this.savedPath, required this.bytesSent});
}

/// Sending side of the file-transfer transport. Streams the payload in
/// a single chunked POST — never reads the whole file into memory.
class HttpFileClient {
  static const _logName = 'sharer.transport.client';

  final HttpClient _http;
  final HmacSigner _signer;

  HttpFileClient({HttpClient? httpClient, HmacSigner? signer})
      : _http = httpClient ?? HttpClient(),
        _signer = signer ?? HmacSigner();

  /// Streams [file] to `http://[host]:[port][TransportProtocol.uploadPath]`.
  ///
  /// When [recipientPsk] is non-null, the request is signed with X-Sharer-
  /// Timestamp / Nonce / Sig headers so a paired peer can authenticate it.
  /// When null, the request is unsigned — slice 4.2 servers fall back to
  /// the trust-network gate; later slices may reject outright.
  ///
  /// [onProgress] is invoked with cumulative bytes sent. Callers can
  /// throttle their UI updates if they want — no rate limiting here.
  Future<UploadResult> upload({
    required String host,
    required int port,
    required FilePayload file,
    required DeviceIdentity sender,
    Uint8List? recipientPsk,
    void Function(int bytesSent)? onProgress,
  }) async {
    final uri =
        Uri.parse('http://$host:$port${TransportProtocol.uploadPath}');
    _log('POST $uri  file=${file.fileName} size=${file.sizeBytes}'
        ' signed=${recipientPsk != null}');

    final request = await _http.postUrl(uri);
    request.headers.contentType = ContentType.parse(
      file.mimeType ?? 'application/octet-stream',
    );
    request.headers.contentLength = file.sizeBytes;
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

    if (recipientPsk != null) {
      final signed = _signer.sign(
        psk: recipientPsk,
        method: 'POST',
        path: TransportProtocol.uploadPath,
        senderDeviceId: sender.id,
        filename: file.fileName,
        filesize: file.sizeBytes,
      );
      request.headers
          .set(TransportProtocol.headerTimestamp, signed.timestamp);
      request.headers.set(TransportProtocol.headerNonce, signed.nonce);
      request.headers.set(TransportProtocol.headerSignature, signed.signature);
    }

    var bytesSent = 0;
    final tracked = file.bytes.map((chunk) {
      bytesSent += chunk.length;
      onProgress?.call(bytesSent);
      return chunk;
    });

    await request.addStream(tracked);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Upload failed: ${response.statusCode} $body',
        uri: uri,
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
  }

  void close() {
    _http.close(force: true);
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
