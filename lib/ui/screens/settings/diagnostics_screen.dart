/// 同步诊断界面：一键跑受控实验，判断「登录」与「访问」各自是否会引发会话冲突
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../platform/connectors/pdd_parse_diag.dart';
import '../../../platform/connectors/sync_diagnostics.dart';
import '../../../platform/storage/platform_auth_store.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final _diag = SyncDiagnostics();
  bool _running = false;
  String _progress = '';
  DiagReport? _report;
  String? _error;

  Future<void> _run() async {
    if (_running) return;
    HapticFeedback.lightImpact();
    setState(() {
      _running = true;
      _error = null;
      _report = null;
      _progress = '准备中…';
    });

    try {
      final report = await _diag.runPddDiagnostics(
        onProgress: (m) {
          if (mounted) setState(() => _progress = m);
        },
      );
      if (!mounted) return;
      setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = PlatformAuthStore();
    final bound = store.isBound('pdd');

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('同步诊断', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1C1C1E),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '复制取件码解析诊断（页面原文 + 丢弃明细）',
            icon: const Icon(Icons.article_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: PddParseDiag.dump()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('解析诊断已复制（含页面正文前 6000 字），可直接粘贴发给开发者'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
          if (_report != null)
            IconButton(
              tooltip: '复制报告',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _report!.toText()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('诊断报告已复制，可直接粘贴发给我'), behavior: SnackBarBehavior.floating),
                  );
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 实验说明
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.science_rounded, color: Color(0xFF007AFF), size: 20),
                    const SizedBox(width: 8),
                    const Text('这个工具要回答什么问题',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  '拼多多的会话冲突到底是「首次登录时踢一次」，还是「每次访问订单都会踢」。'
                  '工具会把「登录」和「访问」严格分开，分三步执行，并记录每一步的 Cookie 指纹变化与落地页面：',
                  style: TextStyle(fontSize: 13, height: 1.45, color: Color(0xFF3A3A3C)),
                ),
                const SizedBox(height: 10),
                _bullet('步骤 1', '全新 WebView + 已保存凭据，仅打开首页（不碰任何订单接口）'),
                _bullet('步骤 2', '全新 WebView + 已保存凭据，打开订单页（页面自身会拉订单）'),
                _bullet('步骤 3', '全新 WebView + 已保存凭据，显式调用订单接口'),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF8EF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    '操作建议：开始前请先确认「拼多多官方 App 处于已登录状态」。'
                    '跑完诊断后立刻打开官方 App 看看有没有被要求重新登录，'
                    '把「哪一步之后被踢」连同报告一起告诉我，就能定位触发点。',
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: Color(0xFF8A5300)),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  bound ? '当前状态：已绑定拼多多凭据' : '当前状态：尚未绑定拼多多账号，请先去设置登录',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: bound ? const Color(0xFF34C759) : Colors.redAccent,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          FilledButton.icon(
            onPressed: (_running || !bound) ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_running ? '正在执行…' : '开始诊断（约 40 秒）'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF007AFF),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),

          if (_running) ...[
            const SizedBox(height: 12),
            Text(_progress, style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
          ],

          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('执行失败：$_error', style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ),
          ],

          if (_report != null) ...[
            const SizedBox(height: 20),
            const Text('诊断结果', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _summaryCard(_report!),
            const SizedBox(height: 12),
            for (final s in _report!.steps) _stepCard(s),
          ],
        ],
      ),
    );
  }

  Widget _bullet(String tag, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: const Color(0xFF007AFF).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(tag, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.4, color: Color(0xFF3A3A3C)))),
        ],
      ),
    );
  }

  Widget _summaryCard(DiagReport r) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('已保存凭据指纹', r.storedFingerprint),
          _kv('Cookie 条数', '${r.storedCount}'),
          _kv('Cookie 总长度', '${r.storedLength}'),
          _kv('关键令牌名称', r.tokenNames.isEmpty ? '（未发现）' : r.tokenNames),
        ],
      ),
    );
  }

  Widget _stepCard(DiagStepResult s) {
    final okColor = s.authOk ? const Color(0xFF34C759) : Colors.redAccent;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: okColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.step, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, height: 1.35)),
          const SizedBox(height: 8),
          _kv('注入后指纹', '${s.injectedFingerprint}（${s.injectedCount} 条）'),
          _kv('访问后指纹', '${s.afterFingerprint}（${s.afterCount} 条）'),
          _kv('令牌是否轮换', s.rotated ? '是（服务端下发了新 Cookie）' : '否'),
          _kv('登录态', s.authOk ? '有效' : '失效 / 被要求登录', valueColor: okColor),
          _kv('页面加载', s.pageLoaded ? '成功' : '失败（结果不参与结论）',
              valueColor: s.pageLoaded ? null : Colors.orange),
          if (s.landedUrl.isNotEmpty) _kv('落地 URL', s.landedUrl, small: true),
          if (s.apiStatus.isNotEmpty) _kv('订单接口', s.apiStatus),
          _kv('耗时', '${s.elapsedMs}ms'),
          if (s.note.isNotEmpty) _kv('备注', s.note, small: true),
        ],
      ),
    );
  }

  Widget _kv(String k, String v, {Color? valueColor, bool small = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(k, style: TextStyle(fontSize: small ? 11.5 : 12.5, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(
                fontSize: small ? 11.5 : 12.5,
                fontWeight: FontWeight.w600,
                color: valueColor ?? const Color(0xFF1C1C1E),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
