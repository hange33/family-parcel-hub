/// 并发控制器 - 限制同时执行的异步任务数量
///
/// 用于防止短时间内大量并发请求触发平台风控
library;

import 'dart:async';
import 'dart:math';

class ConcurrentLimiter {
  final int maxConcurrent;
  int _running = 0;
  final List<Completer> _queue = [];

  ConcurrentLimiter({required this.maxConcurrent});

  /// 执行任务，自动排队控制并发数
  Future<T> run<T>(Future<T> Function() task) async {
    // 如果已达并发上限，加入队列等待
    while (_running >= maxConcurrent) {
      final completer = Completer();
      _queue.add(completer);
      await completer.future;
    }

    _running++;
    try {
      return await task();
    } finally {
      _running--;
      // 唤醒队列中的下一个任务
      if (_queue.isNotEmpty) {
        _queue.removeAt(0).complete();
      }
    }
  }

  /// 批量执行任务，自动控制并发
  Future<List<T>> runAll<T>(List<Future<T> Function()> tasks) async {
    return Future.wait(tasks.map((task) => run(task)));
  }
}

/// 带随机延迟的并发执行器（防风控）
class ThrottledExecutor {
  final int maxConcurrent;
  final Duration minDelay;
  final Duration maxDelay;
  final ConcurrentLimiter _limiter;
  final Random _random = Random();

  ThrottledExecutor({
    this.maxConcurrent = 3,
    this.minDelay = const Duration(milliseconds: 100),
    this.maxDelay = const Duration(milliseconds: 300),
  }) : _limiter = ConcurrentLimiter(maxConcurrent: maxConcurrent);

  /// 执行任务，带随机延迟
  Future<T> execute<T>(Future<T> Function() task) async {
    return _limiter.run(() async {
      // 添加随机延迟，避免请求模式过于规律
      final delayMs = minDelay.inMilliseconds +
          _random.nextInt(maxDelay.inMilliseconds - minDelay.inMilliseconds);
      await Future.delayed(Duration(milliseconds: delayMs));
      return await task();
    });
  }

  /// 批量执行任务
  Future<List<T>> executeAll<T>(List<Future<T> Function()> tasks) async {
    return Future.wait(tasks.map((task) => execute(task)));
  }
}
