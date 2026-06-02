enum TransferDirection { sending, receiving }

enum TransferStatus { pending, inProgress, completed, failed, cancelled }

class Transfer {
  final String id;
  final String peerId;
  final String peerName;
  final String fileName;
  final int totalBytes;
  final int bytesTransferred;
  final TransferDirection direction;
  final TransferStatus status;
  final DateTime startedAt;
  final DateTime? completedAt;

  /// Filesystem path where the file was saved (receive side only).
  final String? savedPath;
  final String? errorMessage;

  /// True when the (outgoing) transfer retains a re-open source so a
  /// failed send can be retried from zero. Lets the UI show/hide the retry
  /// CTA without reaching into the data layer. The re-open factory itself
  /// lives only in the data impl's retry registry, never on this entity —
  /// the entity stays pure/serializable.
  final bool canRetry;

  const Transfer({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.fileName,
    required this.totalBytes,
    required this.direction,
    required this.startedAt,
    this.bytesTransferred = 0,
    this.status = TransferStatus.pending,
    this.completedAt,
    this.savedPath,
    this.errorMessage,
    this.canRetry = false,
  });

  Transfer copyWith({
    int? bytesTransferred,
    TransferStatus? status,
    DateTime? completedAt,
    String? savedPath,
    String? errorMessage,
    bool? canRetry,
  }) {
    return Transfer(
      id: id,
      peerId: peerId,
      peerName: peerName,
      fileName: fileName,
      totalBytes: totalBytes,
      direction: direction,
      startedAt: startedAt,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      status: status ?? this.status,
      completedAt: completedAt ?? this.completedAt,
      savedPath: savedPath ?? this.savedPath,
      errorMessage: errorMessage ?? this.errorMessage,
      canRetry: canRetry ?? this.canRetry,
    );
  }

  /// 0.0–1.0. Returns 0 when [totalBytes] is 0 to avoid divide-by-zero.
  double get progress {
    if (totalBytes <= 0) return 0;
    final ratio = bytesTransferred / totalBytes;
    return ratio.clamp(0, 1).toDouble();
  }

  bool get isTerminal =>
      status == TransferStatus.completed ||
      status == TransferStatus.failed ||
      status == TransferStatus.cancelled;
}
