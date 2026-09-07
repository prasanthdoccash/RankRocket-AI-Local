import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/system_prompt_builder.dart';

void main() {
  test('uses the model prompt when the custom prompt is default', () {
    const modelPrompt = 'You specialize in Indian law.';
    const defaultPrompt = 'You are a helpful AI assistant.';

    expect(
      SystemPromptBuilder.compose(
        modelPrompt: modelPrompt,
        customPrompt: defaultPrompt,
        defaultPrompt: defaultPrompt,
      ),
      modelPrompt,
    );
  });

  test('preserves custom instructions after the model prompt', () {
    expect(
      SystemPromptBuilder.compose(
        modelPrompt: 'You specialize in Indian law.',
        customPrompt: 'Use concise bullet points.',
        defaultPrompt: 'You are a helpful AI assistant.',
      ),
      'You specialize in Indian law.\n\nUse concise bullet points.',
    );
  });

  test('does not treat a previous model prompt as custom instructions', () {
    expect(
      SystemPromptBuilder.compose(
        modelPrompt: 'You specialize in general reasoning.',
        customPrompt: 'Use concise bullet points.',
        defaultPrompt: 'You are a helpful AI assistant.',
      ),
      'You specialize in general reasoning.\n\nUse concise bullet points.',
    );
  });
}
