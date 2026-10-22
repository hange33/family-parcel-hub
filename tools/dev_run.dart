/// 开发期热重载宿主（不参与 App 运行，仅本地开发使用）。
///
/// 作用：启动并常驻 `flutter run`，同时把 build/devcmd.txt 的内容转发到它的 stdin，
/// 从而可以在不重新安装 APK 的情况下触发热重载。
///
/// 用法：
///   dart run tools/dev_run.dart            # 后台常驻启动
///   echo r > build/devcmd.txt              # 触发热重载
///   echo R > build/devcmd.txt              # 触发热重启
///
/// 原因：Flutter 的热重载依赖 flutter_tools 的常驻编译器，无法只通过 VM Service 触发，
/// 因此这里直接驱动 flutter run 自身的标准输入。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final deviceId = args.isNotEmpty ? args[0] : '10AE6M16B4004X4';
  final triggerPath = args.length > 1 ? args[1] : 'build/devcmd.txt';
  final logPath = args.length > 2 ? args[2] : 'build/flutter_run.log';

  final trigger = File(triggerPath);
  final log = File(logPath);
  trigger.parent.createSync(recursive: true);
  log.parent.createSync(recursive: true);
  trigger.writeAsStringSync('');
  log.writeAsStringSync('');

  final proc = await Process.start(
    'flutter',
    ['run', '-d', deviceId, '--vmservice-out-file=build/vmservice.txt'],
    runInShell: true,
  );

  final sink = log.openWrite();

  proc.stdout.listen(sink.add);
  proc.stderr.listen(sink.add);

  var lastCommand = '';
  final timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
    try {
      if (!trigger.existsSync()) return;
      final content = trigger.readAsStringSync().trim();
      if (content.isEmpty || content == lastCommand) return;

      lastCommand = content;
      proc.stdin.writeln(content);
      sink.add(utf8.encode('[dev_run] forwarded: $content\n'));
      trigger.writeAsStringSync('');
      lastCommand = '';
    } catch (e) {
      sink.add(utf8.encode('[dev_run] trigger error: $e\n'));
    }
  });

  final code = await proc.exitCode;
  timer.cancel();
  sink.writeln('[dev_run] flutter run exited with code $code');
  await sink.flush();
  await sink.close();
  exit(code);
}
