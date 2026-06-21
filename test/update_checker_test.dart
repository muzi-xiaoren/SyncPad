import 'package:flutter_test/flutter_test.dart';
import 'package:syncpad/services/update_checker.dart';

void main() {
  group('UpdateChecker.isNewer 版本比较', () {
    test('点分数字逐段比较', () {
      expect(UpdateChecker.isNewer('0.0.2', '0.0.1'), isTrue);
      expect(UpdateChecker.isNewer('0.1.0', '0.0.9'), isTrue);
      expect(UpdateChecker.isNewer('1.0.0', '0.9.9'), isTrue);
    });

    test('相等或更旧返回 false', () {
      expect(UpdateChecker.isNewer('0.0.1', '0.0.1'), isFalse);
      expect(UpdateChecker.isNewer('0.0.1', '0.0.2'), isFalse);
    });

    test('段数不一致按缺位补 0', () {
      expect(UpdateChecker.isNewer('1.0', '1.0.0'), isFalse);
      expect(UpdateChecker.isNewer('1.0.1', '1.0'), isTrue);
    });

    test('忽略非数字后缀（如 1.2.0-beta）', () {
      expect(UpdateChecker.isNewer('1.2.0', '1.2.0-beta'), isFalse);
      expect(UpdateChecker.isNewer('1.3.0-rc1', '1.2.0'), isTrue);
    });
  });
}
