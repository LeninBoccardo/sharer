import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/domain/transfer/transfer_rate.dart';

void main() {
  group('bytesPerSecond', () {
    final t0 = DateTime.utc(2026, 6, 2, 12, 0, 0);

    test('1 MiB over 1.0s is 1048576 B/s', () {
      final r = bytesPerSecond(
        earlierBytes: 0,
        earlierAt: t0,
        laterBytes: 1024 * 1024,
        laterAt: t0.add(const Duration(seconds: 1)),
      );
      expect(r, closeTo(1048576.0, 0.001));
    });

    test('null when the samples share an instant (dt<=0)', () {
      expect(
        bytesPerSecond(
            earlierBytes: 0, earlierAt: t0, laterBytes: 100, laterAt: t0),
        isNull,
      );
    });

    test('null when bytes go backwards (retry reset)', () {
      expect(
        bytesPerSecond(
          earlierBytes: 500,
          earlierAt: t0,
          laterBytes: 100,
          laterAt: t0.add(const Duration(seconds: 1)),
        ),
        isNull,
      );
    });
  });

  group('formatRate', () {
    test('null/0 render nothing', () {
      expect(formatRate(null), isNull);
      expect(formatRate(0), isNull);
    });
    test('byte / KB / MB / GB ranges', () {
      expect(formatRate(512), '512 B/s');
      expect(formatRate(1536), '1.5 KB/s');
      expect(formatRate(4.2 * 1024 * 1024), '4.2 MB/s');
      expect(formatRate(2.0 * 1024 * 1024 * 1024), '2.00 GB/s');
    });
  });

  group('etaSeconds', () {
    test('remaining / rate', () {
      expect(
        etaSeconds(
          totalBytes: 10 * 1024 * 1024,
          bytesTransferred: 4 * 1024 * 1024,
          bytesPerSecond: 2.0 * 1024 * 1024,
        ),
        closeTo(3.0, 0.0001),
      );
    });
    test('null when total unknown or rate unusable', () {
      expect(
          etaSeconds(
              totalBytes: 0, bytesTransferred: 0, bytesPerSecond: 100),
          isNull);
      expect(
          etaSeconds(
              totalBytes: 100, bytesTransferred: 0, bytesPerSecond: null),
          isNull);
    });
    test('0 when nothing remains', () {
      expect(
        etaSeconds(
            totalBytes: 100, bytesTransferred: 100, bytesPerSecond: 50),
        0,
      );
    });
  });

  group('formatEta', () {
    test('seconds / minutes / hours formatting', () {
      expect(formatEta(12), '~12s left');
      expect(formatEta(0), '~0s left');
      expect(formatEta(185), '~3m 5s left');
      expect(formatEta(180), '~3m left');
      expect(formatEta(3720), '~1h 2m left');
      expect(formatEta(3600), '~1h left');
    });
    test('null / NaN / Infinity render nothing', () {
      expect(formatEta(null), isNull);
      expect(formatEta(double.nan), isNull);
      expect(formatEta(double.infinity), isNull);
    });
  });

  group('rateEtaLabel', () {
    test('joins / falls back to whichever side exists', () {
      expect(rateEtaLabel(null, null), '');
      expect(rateEtaLabel('4.2 MB/s', null), '4.2 MB/s');
      expect(rateEtaLabel(null, '~12s left'), '~12s left');
      expect(rateEtaLabel('4.2 MB/s', '~12s left'), '4.2 MB/s · ~12s left');
    });
  });
}
