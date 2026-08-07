import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/context_recommender.dart';

void main() {
  const int gb = 1024 * 1024 * 1024;

  test('recommends 1024 under 6 GB', () {
    expect(ContextRecommender.recommendContextSize(5 * gb), 1024);
    expect(ContextRecommender.recommendContextSize((5 * gb) + (999 * 1024 * 1024)), 1024);
  });

  test('recommends 4096 from exactly 6 GB up to just under 8 GB', () {
    expect(ContextRecommender.recommendContextSize(6 * gb), 4096);
    expect(ContextRecommender.recommendContextSize((7 * gb) + (512 * 1024 * 1024)), 4096);
  });

  test('recommends 8192 at 8 GB and above', () {
    expect(ContextRecommender.recommendContextSize(8 * gb), 8192);
    expect(ContextRecommender.recommendContextSize(12 * gb), 8192);
  });

  test('formats RAM bytes as whole GB', () {
    expect(ContextRecommender.formatRamBytes(8 * gb), '8 GB');
    expect(ContextRecommender.formatRamBytes(12 * gb), '12 GB');
  });
}
