/// Trims a chat history to fit inside the model's context window, dropping
/// the oldest messages first. Never mutates its inputs.
///
/// Budget: 25% of the window is reserved for the reply; the rest is available
/// for the system prompt + history. Per-message template delimiters are
/// accounted for with a conservative constant.
class ChatContextTrimmer {
  static const int templateTokensPerMessage = 16;
  static const int templateTokensForSystemPrompt = 16;
  static const int minReserve = 64;

  /// Returns up to [messages] newest entries (in original order) that fit
  /// alongside [systemPrompt] within [contextSize].
  static Future<List<Map<String, String>>> trimHistory({
    required List<Map<String, String>> messages,
    required String systemPrompt,
    required int contextSize,
    required Future<int> Function(String text) countTokens,
  }) async {
    if (contextSize <= 0) return List.of(messages);
    if (messages.isEmpty) return const [];

    final systemCost = systemPrompt.trim().isEmpty
        ? 0
        : await countTokens(systemPrompt) + templateTokensForSystemPrompt;

    final costs = <int>[];
    for (final m in messages) {
      final content = m['content'] ?? '';
      costs.add(content.isEmpty ? 0 : await countTokens(content) + templateTokensPerMessage);
    }

    var reserve = contextSize ~/ 4;
    if (reserve > contextSize) reserve = contextSize;
    var budget = contextSize - reserve;
    if (systemCost > budget) {
      // System prompt alone needs more prompt room: shrink the reserve to its
      // minimum and retry.
      budget = contextSize - minReserve;
      if (systemCost > budget) {
        return List.of(messages); // pathological; surface the error as-is
      }
    }

    final kept = <Map<String, String>>[];
    var used = systemCost;
    for (var i = messages.length - 1; i >= 0; i--) {
      final cost = costs[i];
      if (used + cost > budget) {
        if (kept.isEmpty) kept.insert(0, messages[i]); // always keep newest
        break;
      }
      used += cost;
      kept.insert(0, messages[i]);
    }
    return kept;
  }
}
