// Pure-Dart throughput + ETA math for the transfer UI. No Flutter import
// (domain layer) so it is unit-testable in isolation; the widget that drives
// it (TransferRateLine) injects the samples. All functions are null-safe for
// the "unknown / can't compute yet" cases the UI hits early in a transfer.

/// Bytes-per-second between two samples. Returns null when the time delta is
/// non-positive (same-instant samples) or bytes went backwards (a retry reset
/// to 0) — callers then render no rate rather than a bogus number.
double? bytesPerSecond({
  required int earlierBytes,
  required DateTime earlierAt,
  required int laterBytes,
  required DateTime laterAt,
}) {
  final dtMicros = laterAt.difference(earlierAt).inMicroseconds;
  if (dtMicros <= 0) return null;
  final db = laterBytes - earlierBytes;
  if (db <= 0) return null;
  return db / (dtMicros / 1e6);
}

/// Human rate label, e.g. '4.2 MB/s'. null/<=0 -> null (render nothing).
String? formatRate(double? bytesPerSecond) {
  final r = bytesPerSecond;
  if (r == null || r <= 0) return null;
  if (r < 1024) return '${r.toStringAsFixed(0)} B/s';
  if (r < 1024 * 1024) return '${(r / 1024).toStringAsFixed(1)} KB/s';
  if (r < 1024 * 1024 * 1024) {
    return '${(r / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  return '${(r / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
}

/// Seconds remaining given remaining bytes and a rate. null when total is
/// unknown (<=0), the rate is unusable, or nothing remains is 0.
double? etaSeconds({
  required int totalBytes,
  required int bytesTransferred,
  required double? bytesPerSecond,
}) {
  final r = bytesPerSecond;
  if (totalBytes <= 0 || r == null || r <= 0) return null;
  final remaining = totalBytes - bytesTransferred;
  if (remaining <= 0) return 0;
  return remaining / r;
}

/// '~12s left' / '~3m 5s left' / '~1h 2m left'. null -> null.
String? formatEta(double? seconds) {
  final s = seconds;
  if (s == null || s.isNaN || s.isInfinite) return null;
  final total = s.ceil();
  if (total <= 0) return '~0s left';
  if (total < 60) return '~${total}s left';
  if (total < 3600) {
    final m = total ~/ 60;
    final sec = total % 60;
    return sec == 0 ? '~${m}m left' : '~${m}m ${sec}s left';
  }
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  return m == 0 ? '~${h}h left' : '~${h}h ${m}m left';
}

/// Joins a rate + eta into one trailing string, e.g.
/// '4.2 MB/s · ~12s left'. Either side may be absent; returns '' when both
/// are null so the caller can skip rendering the line.
String rateEtaLabel(String? rate, String? eta) {
  if (rate == null && eta == null) return '';
  if (rate == null) return eta!;
  if (eta == null) return rate;
  return '$rate · $eta';
}
