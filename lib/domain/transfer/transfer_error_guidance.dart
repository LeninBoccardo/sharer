import '../entities/transfer.dart' show TransferDirection;

/// What the user can do about a failed transfer. The UI maps this to a
/// concrete CTA (a Retry button only when the transfer also reports
/// canRetry — this is just the *suggested* action).
enum TransferErrorAction { retry, rePair, retryOrRePair, freeSpace, none }

/// Human-facing guidance derived from a raw transfer error string. [raw] is
/// the original `Transfer.errorMessage` (an `e.toString()`) kept verbatim for
/// the technical-details view.
class TransferErrorGuidance {
  const TransferErrorGuidance({
    required this.headline,
    required this.detail,
    required this.action,
    required this.raw,
  });

  /// One line, shown on the card.
  final String headline;

  /// Full sentence(s), shown in the detail sheet.
  final String detail;
  final TransferErrorAction action;
  final String raw;
}

/// Maps [errorMessage] (the verbatim `Transfer.errorMessage`) to friendly
/// guidance. Pure: deterministic on its input, no IO, depends only on the
/// [TransferDirection] domain enum — so it lives in domain and is unit-
/// testable headless.
///
/// Keyed on stable substrings of the transport exceptions' `toString()`
/// outputs (UploadStatusException / UnpinnedPeerException /
/// PayloadSizeMismatchException) and the English, non-localized `dart:io`
/// SocketException/HandshakeException messages. An unknown string falls
/// through to a generic failure with the raw error still preserved.
TransferErrorGuidance mapTransferError(
  String? errorMessage, {
  required TransferDirection direction,
}) {
  final raw = errorMessage ?? '';
  final m = raw.toLowerCase();

  // Peer removed us: UploadStatusException 403 + reason=unknown-sender.
  if (m.contains('reason=unknown-sender')) {
    return TransferErrorGuidance(
      headline: 'This device removed you',
      detail: "They've unpaired this device, so it won't accept files from "
          'you anymore. Re-pair to share again.',
      action: TransferErrorAction.rePair,
      raw: raw,
    );
  }

  // Receiver out of room: 507 reason=storage-full (sender) or the server's
  // own "upload exceeded size bound" message (receive side).
  if (m.contains('storage-full') || m.contains('exceeded size bound')) {
    return TransferErrorGuidance(
      headline: 'Not enough space',
      detail: 'The other device ran out of room for this file. Free up space '
          'on the receiving device and try again.',
      action: TransferErrorAction.freeSpace,
      raw: raw,
    );
  }

  // Paired before TLS pinning existed: UnpinnedPeerException.
  if (m.contains('no certificate fingerprint') ||
      m.contains('re-pair the device')) {
    return TransferErrorGuidance(
      headline: 'Secure connection not set up',
      detail: 'This device was paired before secure transfers were enabled. '
          'Re-pair to refresh the security details.',
      action: TransferErrorAction.rePair,
      raw: raw,
    );
  }

  // Stale/wrong peer IP (Realme bonsoir flake) + general unreachable.
  const unreachable = [
    'handshakeexception',
    'failed host lookup',
    'connection refused',
    'connection timed out',
    'connection timed-out',
    'network is unreachable',
    'no route to host',
    'connection reset',
    'connection closed',
    'socketexception',
    'os error',
  ];
  if (unreachable.any(m.contains)) {
    return TransferErrorGuidance(
      headline: 'Peer not reachable',
      detail: 'They may be offline or on another network. Make sure both '
          'devices are on the same Wi-Fi, then try again. If it keeps '
          'failing, re-pair.',
      action: TransferErrorAction.retryOrRePair,
      raw: raw,
    );
  }

  // Source changed under us mid-send: PayloadSizeMismatchException.
  if (m.contains('payload size mismatch')) {
    return TransferErrorGuidance(
      headline: 'File changed while sending',
      detail: 'The file changed or was moved during the transfer. Pick or '
          'share it again and retry.',
      action: TransferErrorAction.retry,
      raw: raw,
    );
  }

  // Any other non-2xx upload response (bare 401, other 4xx/5xx).
  if (m.startsWith('upload failed:')) {
    return TransferErrorGuidance(
      headline: 'The other device declined the file',
      detail: "They didn't accept the transfer. This is usually temporary (a "
          'clock or signing hiccup). Try again; if it persists, re-pair.',
      action: TransferErrorAction.retryOrRePair,
      raw: raw,
    );
  }

  // Fallback.
  return TransferErrorGuidance(
    headline: 'Transfer failed',
    detail: direction == TransferDirection.sending
        ? 'Something went wrong sending this file. Try again, or re-pair the '
            'device if it keeps failing.'
        : 'Something went wrong receiving this file. Ask the sender to try '
            'again.',
    action: direction == TransferDirection.sending
        ? TransferErrorAction.retryOrRePair
        : TransferErrorAction.none,
    raw: raw.isEmpty ? 'No error detail was recorded.' : raw,
  );
}
