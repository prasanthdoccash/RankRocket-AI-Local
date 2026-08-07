import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/chat_context_trim.dart';

// 1 token per character, so message costs are predictable.
Future<int> _count(String text) async => text.length;

Map<String, String> _msg(String role, String content) =>
    {'role': role, 'content': content};

void main() {
  test('keeps all messages when they fit under the budget', () async {
    final messages = [
      _msg('user', 'aa'), // 2 + 16 = 18
      _msg('assistant', 'bb'), // 18
    ];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: '',
      contextSize: 100, // reserve 25, budget 75
      countTokens: _count,
    );
    expect(trimmed, hasLength(2));
    expect(trimmed.first['role'], 'user');
    expect(trimmed.last['role'], 'assistant');
  });

  test('drops oldest messages on overflow, keeping newest', () async {
    final messages = [
      _msg('user', 'x' * 30), // 30 + 16 = 46
      _msg('assistant', 'y' * 30), // 46
      _msg('user', 'z' * 5), // 5 + 16 = 21
    ];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: '',
      contextSize: 100, // budget 75; 21 + 46 = 67 fits, +46 would exceed
      countTokens: _count,
    );
    expect(trimmed, hasLength(2));
    expect(trimmed.first['content'], 'y' * 30);
    expect(trimmed.last['content'], 'z' * 5);
  });

  test('shrinks the reserve when the system prompt needs the room', () async {
    // contextSize 400 -> normal reserve 100 -> budget 300.
    // systemPrompt 'p'*310 -> cost 310 + 16 = 326 > 300, so the trimmer
    // retries with minReserve (64) -> budget 336; 326 fits.
    // Newest 'z'*5 (21) would push to 347 > 336, so only it is kept.
    final messages = [
      _msg('user', 'x' * 30),
      _msg('assistant', 'y' * 30),
      _msg('user', 'z' * 5),
    ];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: 'p' * 310,
      contextSize: 400,
      countTokens: _count,
    );
    expect(trimmed, hasLength(1));
    expect(trimmed.single['content'], 'z' * 5);
  });

  test('counts the system prompt against the budget', () async {
    final messages = [
      _msg('user', 'a' * 30), // 46
      _msg('user', 'b' * 30), // 46
    ];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: 's' * 10, // 10 + 16 = 26
      contextSize: 100, // budget 75; 26 + 46 = 72 fits, +46 would exceed
      countTokens: _count,
    );
    expect(trimmed, hasLength(1));
    expect(trimmed.single['content'], 'b' * 30);
  });

  test('returns messages unchanged when a single message cannot fit', () async {
    final messages = [_msg('user', 'x' * 90)]; // 90 + 16 = 106 > any budget
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: '',
      contextSize: 100, // max budget even at minReserve is 100 - 64 = 36
      countTokens: _count,
    );
    expect(trimmed, hasLength(1));
    expect(trimmed.single['content'], 'x' * 90);
  });

  test('returns empty when there are no messages', () async {
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: const [],
      systemPrompt: '',
      contextSize: 100,
      countTokens: _count,
    );
    expect(trimmed, isEmpty);
  });

  test('returns all messages when contextSize is not positive', () async {
    final messages = [_msg('user', 'anything')];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: '',
      contextSize: 0,
      countTokens: _count,
    );
    expect(trimmed, hasLength(1));
  });
}
