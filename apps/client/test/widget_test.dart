
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:daymark/app/daymark_app.dart';

import 'support/test_app.dart';

void main() {
  testWidgets('DayMark app starts successfully', (WidgetTester tester) async {
    final controller = await makeController();

    await tester.pumpWidget(DayMarkApp(controller: controller));
    await tester.pump();

    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
