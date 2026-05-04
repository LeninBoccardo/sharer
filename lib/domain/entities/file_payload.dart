/// Single-shot streamed file payload. Consumers must drain [bytes] at most
/// once. file_picker's `readStream` is single-shot too — matches the
/// underlying constraint, so we don't pretend otherwise.
class FilePayload {
  final String fileName;
  final int sizeBytes;
  final Stream<List<int>> bytes;
  final String? mimeType;

  const FilePayload({
    required this.fileName,
    required this.sizeBytes,
    required this.bytes,
    this.mimeType,
  });
}
