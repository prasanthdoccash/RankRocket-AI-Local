import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/llm_service.dart';

void main() {
  test('contextSize is 0 when no model is loaded', () {
    final llm = LlmService();
    expect(llm.contextSize, 0);
  });

  test('countTokens throws a StateError when no model is loaded', () async {
    final llm = LlmService();
    await expectLater(
      llm.countTokens('hello'),
      throwsA(isA<StateError>()),
    );
  });
}
