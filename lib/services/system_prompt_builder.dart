class SystemPromptBuilder {
  const SystemPromptBuilder._();

  static String compose({
    required String modelPrompt,
    required String customPrompt,
    required String defaultPrompt,
  }) {
    final model = modelPrompt.trim();
    final custom = customPrompt.trim();
    if (model.isEmpty) return custom;
    if (custom.isEmpty || custom == defaultPrompt.trim()) return model;
    return '$model\n\n$custom';
  }
}
