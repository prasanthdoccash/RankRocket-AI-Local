/// Maps a device's total RAM to a safe context-window recommendation.
class ContextRecommender {
  static const int lowContext = 1024;
  static const int midContext = 4096;
  static const int highContext = 8192;

  static const int _sixGb = 6 * 1024 * 1024 * 1024;
  static const int _eightGb = 8 * 1024 * 1024 * 1024;

  /// < 6 GB -> 1024, 6-7.9 GB -> 4096, >= 8 GB -> 8192.
  static int recommendContextSize(int totalRamBytes) {
    if (totalRamBytes < _sixGb) return lowContext;
    if (totalRamBytes < _eightGb) return midContext;
    return highContext;
  }

  /// Formats raw RAM bytes as a whole-number GB label, e.g. "8 GB".
  static String formatRamBytes(int totalRamBytes) {
    final gb = totalRamBytes / (1024 * 1024 * 1024);
    return '${gb.round()} GB';
  }
}
