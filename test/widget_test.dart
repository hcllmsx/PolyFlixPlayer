// 影现播放器 冒烟测试：验证应用可正常构建并加载主页。
import 'package:flutter_test/flutter_test.dart';
import 'package:polyflix_player/main.dart';

void main() {
  testWidgets('App 启动并显示主页', (WidgetTester tester) async {
    await tester.pumpWidget(const PolyFlixApp());
    await tester.pumpAndSettle();

    // 主页标题与主文案应存在
    expect(find.text('影现播放器'), findsWidgets);
    expect(find.text('一个特殊的万能视频播放器'), findsOneWidget);
  });
}
