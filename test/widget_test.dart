// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_ocr_read/main.dart';

void main() {
  testWidgets('显示预览区并有拍照按钮', (WidgetTester tester) async {
    // 构建应用并触发一帧
    await tester.pumpWidget(const MyApp());

    // 预览区标题存在
    expect(find.text('预览区'), findsOneWidget);
    // 拍照按钮文案存在
    expect(find.text('拍照'), findsOneWidget);
  });
}
