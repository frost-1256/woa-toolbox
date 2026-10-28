import '../gpt/gpt_diff.dart';

enum PlanKind {
  backupGpt,
  backupPartitions,
  restoreGpt,
  restorePartition,
  fastbootBoot,
  returnToAndroid,
}

enum StepKind { readDevice, writeDevice, writeFile, verify }

/// 計画の 1 ステップ。プレビューでコマンド全文を表示するために
/// [commandPreview] を必ず持つ（設計書 §5.7 / §7）。
class PlanStep {
  const PlanStep({
    required this.description,
    required this.commandPreview,
    required this.kind,
  });

  final String description;
  final String commandPreview;
  final StepKind kind;
}

/// 操作計画。Plan → Preview → Confirm → Execute の対象（設計書 §2）。
///
/// プランは対象端末のシリアルとレイアウトフィンガープリントに束縛され、
/// 有効期限（既定 10 分）を持つ。実行直前に [checkBinding] で再検証し、
/// 状態が変わっていたら実行しない。
class OperationPlan {
  OperationPlan({
    required this.kind,
    required this.title,
    required this.deviceSerial,
    required this.layoutFingerprint,
    required this.steps,
    required this.destructive,
    this.diff,
    this.warnings = const [],
    this.data = const {},
    DateTime? createdAt,
    this.ttl = const Duration(minutes: 10),
  }) : createdAt = createdAt ?? DateTime.now();

  final PlanKind kind;
  final String title;
  final String deviceSerial;
  final String layoutFingerprint;
  final List<PlanStep> steps;
  final bool destructive;
  final GptDiff? diff;
  final List<String> warnings;

  /// 実行器向けの機械可読ペイロード（LBA 範囲や対象パーティション等）。
  final Map<String, Object?> data;

  final DateTime createdAt;
  final Duration ttl;

  String get id =>
      'plan-${kind.name}-${createdAt.microsecondsSinceEpoch}';

  DateTime get expiresAt => createdAt.add(ttl);

  bool isExpired([DateTime? now]) =>
      (now ?? DateTime.now()).isAfter(expiresAt);

  /// 実行直前の束縛検証。失敗したら StateError。
  void checkBinding({
    required String serial,
    required String layoutFingerprint,
    DateTime? now,
  }) {
    if (isExpired(now)) {
      throw StateError('プランの有効期限が切れています。計画を作り直してください');
    }
    if (serial != deviceSerial) {
      throw StateError('プランの対象端末と現在の端末が異なります');
    }
    if (layoutFingerprint != this.layoutFingerprint) {
      throw StateError('端末の GPT レイアウトがプラン作成時から変わっています');
    }
  }
}

/// プランの JSON 表現（MCP の plan 系ツールの応答用）。
Map<String, Object?> planToJson(OperationPlan plan) => {
      'planId': plan.id,
      'kind': plan.kind.name,
      'title': plan.title,
      'deviceSerial': plan.deviceSerial,
      'layoutFingerprint': plan.layoutFingerprint,
      'destructive': plan.destructive,
      'createdAt': plan.createdAt.toUtc().toIso8601String(),
      'expiresAt': plan.expiresAt.toUtc().toIso8601String(),
      'warnings': plan.warnings,
      if (plan.diff != null)
        'diff': [
          for (final c in plan.diff!.changes)
            {'kind': c.kind.name, 'name': c.name, 'detail': c.detail},
        ],
      'steps': [
        for (final s in plan.steps)
          {
            'description': s.description,
            'command': s.commandPreview,
            'kind': s.kind.name,
          },
      ],
    };
