import 'package:flutter_test/flutter_test.dart';

import 'package:million_chanting/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const MillionChantingApp());
    // Model loading is async and touches the filesystem/native bindings,
    // which this widget test's fake asset bundle can't fully satisfy -
    // just confirm the initial frame (loading spinner) renders without
    // throwing, rather than waiting for model load to finish.
    await tester.pump();
  });
}
