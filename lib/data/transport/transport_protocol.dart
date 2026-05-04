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

  /// Sender's stable device id (UUID). Slice 4 will replace this with
  /// an HMAC-signed token; for now it's an unauthenticated label.
  static const String headerDeviceId = 'x-sharer-deviceid';

  /// URL-encoded human-readable device name from the sender.
  static const String headerDeviceName = 'x-sharer-devicename';
}
