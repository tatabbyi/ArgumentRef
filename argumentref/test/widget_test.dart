import 'package:argumentref/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the live conversation dashboard', (tester) async {
    await tester.pumpWidget(const ArgumentRefApp());

    expect(find.text('Argument Referee'), findsOneWidget);
    expect(find.text('Live conversation'), findsOneWidget);
    expect(find.text('Speaker balance'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

    await tester.tap(find.text('Checks'));
    await tester.pumpAndSettle();

    expect(find.text('Fact-check feed'), findsOneWidget);
  });

  test('detects checkable claims from transcript text', () {
    expect(
      isCheckableClaim('Revenue increased by 18 percent after launch'),
      isTrue,
    );
    expect(isCheckableClaim('I agree with the next step'), isFalse);
  });
}
