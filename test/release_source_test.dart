import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/constants.dart';

void main() {
  test('in-app updates follow this fork, not the upstream repo', () {
    expect(AppConstants.githubRepo, 'lord3nd3r/cross-platform-llm-client');
    expect(AppConstants.githubRepo.contains('orailnoor'), isFalse);
  });
}
