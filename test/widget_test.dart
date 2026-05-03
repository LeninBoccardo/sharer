import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/app.dart';

void main() {
  testWidgets('Home screen renders title and empty state', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SharerApp()));
    await tester.pumpAndSettle();

    expect(find.text('Sharer'), findsOneWidget);
    expect(find.text('Nearby devices'), findsOneWidget);
    expect(find.text('No devices found yet'), findsOneWidget);
    expect(find.byIcon(Icons.devices_other), findsOneWidget);
  });
}
