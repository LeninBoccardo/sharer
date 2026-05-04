/// Events emitted by [HttpFileServer] as files arrive. The
/// [TransferServiceImpl] consumes these and lifts them into [Transfer]
/// updates on the public stream.
sealed class IncomingEvent {
  const IncomingEvent({required this.id});
  final String id;
}

class IncomingStarted extends IncomingEvent {
  final String fileName;
  final int totalBytes;
  final String senderId;
  final String senderName;
  const IncomingStarted({
    required super.id,
    required this.fileName,
    required this.totalBytes,
    required this.senderId,
    required this.senderName,
  });
}

class IncomingProgress extends IncomingEvent {
  final int bytesReceived;
  const IncomingProgress({required super.id, required this.bytesReceived});
}

class IncomingCompleted extends IncomingEvent {
  final String savedPath;
  const IncomingCompleted({required super.id, required this.savedPath});
}

class IncomingFailed extends IncomingEvent {
  final String error;
  const IncomingFailed({required super.id, required this.error});
}
