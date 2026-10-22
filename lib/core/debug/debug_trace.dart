/// Debug 追踪工具
///
/// compact: 每个事件一行，方便 grep
/// verbose: 完整输出，开发时使用
library;

import '../models/package.dart';
import '../models/package_status.dart';
import '../parser/parse_result.dart';

enum DebugLevel { compact, verbose }

class DebugTrace {
  static bool enabled = true;
  static DebugLevel level = DebugLevel.verbose;

  // ── 基础工具 ─────────────────────────────────────────────

  static void separator(String label) {
    if (!enabled) return;
    if (level == DebugLevel.verbose) {
      print('');
      print('═══════════════════════════════════════════════════');
      print('  $label');
      print('═══════════════════════════════════════════════════');
    }
  }

  static void error(String message, {Object? error, StackTrace? stackTrace}) {
    if (!enabled) return;
    print('ERROR: $message');
    if (error != null) print('  error: $error');
    if (stackTrace != null && level == DebugLevel.verbose) {
      print('  stack: $stackTrace');
    }
  }

  // ── Pipeline 事件 ────────────────────────────────────────

  static void ocr(String rawText) {
    if (!enabled) return;
    if (level == DebugLevel.verbose) {
      separator('OCR RESULT');
      print('rawText:\n  $rawText\n  length: ${rawText.length}');
    }
  }

  static void parse(ParseResult result, {int? index}) {
    if (!enabled) return;
    final tag = index != null ? '#$index' : '';
    if (level == DebugLevel.compact) {
      print('PARSE$tag: courier=${result.courier.value.displayName} '
          'tracking=${result.trackingNumber.value} '
          'status=${result.status.value.label} '
          'conf=${result.overallConfidence.toStringAsFixed(2)}');
    } else {
      separator('PARSE RESULT $tag');
      print('courier: ${result.courier.value.displayName} '
          '(${result.courier.confidence}, ${result.courier.source})');
      print('pickupCode: ${result.pickupCode.value} '
          '(${result.pickupCode.confidence})');
      print('trackingNumber: ${result.trackingNumber.value} '
          '(${result.trackingNumber.confidence})');
      print('location: ${result.location.value} '
          '(${result.location.confidence}, ${result.location.source})');
      print('status: ${result.status.value.label} '
          '(${result.status.confidence}, ${result.status.source})');
      print('overallConfidence: ${result.overallConfidence}');
      print('isValid: ${result.isValid} canCreatePackage: ${result.canCreatePackage}');
      if (result.allWarnings.isNotEmpty) {
        for (final w in result.allWarnings) {
          print('  warning: $w');
        }
      }
    }
  }

  static void abort(String reason) {
    if (!enabled) return;
    print('ABORT: $reason');
  }

  static void dedupe({required String method, required bool hit, String? tracking}) {
    if (!enabled) return;
    print('DEDUPE: method=$method hit=$hit tracking=${tracking ?? ""}');
  }

  static void merge(String existingId, String incomingTracking) {
    if (!enabled) return;
    print('MERGE: existing=$existingId incoming=$incomingTracking');
  }

  // ── 保留的详细输出（verbose only）────────────────────────

  static void ocrResult(String rawText) {
    if (!enabled || level != DebugLevel.verbose) return;
    separator('OCR RESULT');
    print('rawText:\n  $rawText\n  length: ${rawText.length}');
  }

  static void parseResult(ParseResult result, {int? index}) => parse(result, index: index);

  static void normalizedText(String original, String normalized, String fingerprint) {
    if (!enabled || level != DebugLevel.verbose) return;
    separator('NORMALIZED TEXT');
    print('original: $original');
    print('normalized: $normalized');
    print('fingerprint: $fingerprint');
  }

  static void dedupeResult({
    required String method,
    required bool isDuplicate,
    int? existingIndex,
    String? existingId,
    String? reason,
  }) {
    if (!enabled) return;
    dedupe(method: method, hit: isDuplicate, tracking: reason);
  }

  static void packageCreated(Package package) {
    if (!enabled) return;
    if (level == DebugLevel.compact) {
      print('PACKAGE: id=${package.id} courier=${package.courier.displayName} '
          'tracking=${package.trackingNumber} status=${package.status.label}');
    } else {
      separator('PACKAGE CREATED');
      print('id: ${package.id}');
      print('courier: ${package.courier.displayName}');
      print('trackingNumber: ${package.trackingNumber}');
      print('pickupCode: ${package.pickupCode.isEmpty ? "(empty)" : package.pickupCode}');
      print('location: ${package.location.isEmpty ? "(empty)" : package.location}');
      print('status: ${package.status.label}');
      print('transitFingerprint: ${package.transitFingerprint ?? "(null)"}');
    }
  }

  static void confirmationCreated({
    required String id,
    required double confidence,
    required CourierType courier,
    required String pickupCode,
    required String location,
    required PackageStatus status,
  }) {
    if (!enabled) return;
    if (level == DebugLevel.compact) {
      print('CONFIRMATION: id=$id conf=${confidence.toStringAsFixed(2)} '
          'courier=${courier.displayName} status=${status.label}');
    } else {
      separator('PENDING CONFIRMATION CREATED');
      print('id: $id');
      print('confidence: $confidence');
      print('courier: ${courier.displayName}');
      print('pickupCode: ${pickupCode.isEmpty ? "(empty)" : pickupCode}');
      print('location: ${location.isEmpty ? "(empty)" : location}');
      print('status: ${status.label}');
    }
  }
}
