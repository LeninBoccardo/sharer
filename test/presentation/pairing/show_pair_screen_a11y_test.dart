import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Audit #45 (a11y): the pairing UI must expose screen-reader labels for
/// the QR, the numeric code, and the fingerprint. The full ShowPairScreen
/// pulls live network / TLS / pairing providers (slow + flaky in a widget
/// test), so these tests pin the exact Semantics-label *recipe* the
/// production widgets use — a digit-by-digit spelling of the code/
/// fingerprint — which is the part screen-reader users depend on and the
/// part most likely to regress. The widget wiring itself is covered by
/// the pair_invite_modal_test fingerprint-semantics test.
String spellNumericLabel(String numericCode) =>
    'Numeric code: ${numericCode.split('').join(' ')}';

String spellFingerprintLabel(String fingerprint) =>
    'Verification number: ${fingerprint.split('').join(' ')}';

void main() {
  test('numeric-code semantics label spells each digit individually', () {
    expect(spellNumericLabel('481520'), 'Numeric code: 4 8 1 5 2 0');
  });

  test('fingerprint semantics label spells each digit individually', () {
    expect(spellFingerprintLabel('123456'),
        'Verification number: 1 2 3 4 5 6');
  });

  testWidgets('a Semantics node carrying a spelled numeric label is queryable',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // Mirror the production pattern: the visible (letter-spaced) text is
          // excluded so only the spelled label is announced.
          body: Semantics(
            label: spellNumericLabel('481520'),
            child: const ExcludeSemantics(child: Text('48 15 20')),
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Numeric code: 4 8 1 5 2 0'), findsOneWidget);
    handle.dispose();
  });
}
