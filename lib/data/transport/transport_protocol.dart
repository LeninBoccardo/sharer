/// Wire-format constants shared by [HttpFileServer] (receive side) and
/// [HttpFileClient] (send side). Keeping them in one place stops the
/// two ends from drifting apart silently.
///
/// Headers chosen instead of multipart so the body can be a single
/// streamed octet-stream — no in-memory buffering of file content.
abstract final class TransportProtocol {
  static const int defaultPort = 8080;
  static const String uploadPath = '/upload';

  /// URL-encoded filename. Decoded with [Uri.decodeComponent] on the
  /// server. Required.
  static const String headerFileName = 'x-sharer-filename';

  /// Total payload size in bytes. Used by the server only for the
  /// progress total. Receiver streams until the body ends regardless.
  static const String headerFileSize = 'x-sharer-filesize';

  /// Sender's stable device id (UUID). On signed requests this is also
  /// the lookup key for the receiver's PSK.
  static const String headerDeviceId = 'x-sharer-deviceid';

  /// URL-encoded human-readable device name from the sender.
  static const String headerDeviceName = 'x-sharer-devicename';

  // ---- Slice 4.2: HMAC authentication. ----
  // All three are required as a set; if any is present, the others must
  // be too. Signed values cover the request manifest (method, path,
  // sender, filename, size). See HmacSigner.canonicalString.

  /// Sender's clock at request time, in unix milliseconds (UTC).
  static const String headerTimestamp = 'x-sharer-timestamp';

  /// Random 128-bit nonce, base64-encoded. Receiver dedupes within the
  /// nonce TTL window to defeat replay.
  static const String headerNonce = 'x-sharer-nonce';

  /// Base64 HMAC-SHA256 over the canonical string built from the other
  /// fields, using the receiver's per-pair PSK.
  static const String headerSignature = 'x-sharer-sig';
}
