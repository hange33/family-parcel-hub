class Metrics {
  static final _counts = <String, int>{};

  static void inc(String key) {
    _counts[key] = (_counts[key] ?? 0) + 1;
  }

  static void report() {
    print('=== METRICS ===');
    _counts.forEach((k, v) => print('  $k: $v'));
  }

  static void reset() => _counts.clear();
}