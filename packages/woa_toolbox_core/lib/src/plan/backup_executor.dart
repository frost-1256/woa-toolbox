import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../backup/manifest.dart';
import '../gpt/gpt_reader.dart';
import 'plan.dart';

/// バックアップ系プランの実行器（読み取り専用）。
///
/// 実行直前にプランの束縛（シリアル・フィンガープリント・有効期限）を
/// 再検証する。読み取りは [LbaReader] 経由で、受信バイト数は
/// AdbLbaReader が期待サイズと照合する（設計書 §7）。
/// 復元系プランの実行はここでは扱わない。
class BackupExecutor {
  const BackupExecutor();

  /// [plan]（backupGpt / backupPartitions）を実行し、[outDir] に
  /// ファイルと manifest.json を書き、manifest を返す。
  Future<BackupManifest> execute(
    OperationPlan plan, {
    required LbaReader reader,
    required Directory outDir,
    required String serial,
    required String productDevice,
    required String currentFingerprint,
    void Function(String line)? onProgress,
  }) async {
    if (plan.kind != PlanKind.backupGpt &&
        plan.kind != PlanKind.backupPartitions) {
      throw ArgumentError('この実行器はバックアップ系プラン専用です: ${plan.kind}');
    }
    plan.checkBinding(serial: serial, layoutFingerprint: currentFingerprint);

    await outDir.create(recursive: true);
    final entries = <BackupFileEntry>[];

    Future<void> saveRead(
        String fileName, String partitionName, int startLba, int count) async {
      onProgress?.call('$partitionName を読んでいます（LBA $startLba, $count セクタ）');
      final bytes = await reader.readLbas(startLba, count);
      final file = File('${outDir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes);
      entries.add(BackupFileEntry(
        fileName: fileName,
        partitionName: partitionName,
        sizeBytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      ));
      onProgress?.call('$fileName を保存しました（${bytes.length} バイト）');
    }

    switch (plan.kind) {
      case PlanKind.backupGpt:
        await saveRead(
          'gpt_primary.bin',
          'gpt-primary',
          plan.data['primaryStart'] as int,
          plan.data['primaryCount'] as int,
        );
        await saveRead(
          'gpt_backup.bin',
          'gpt-backup',
          plan.data['backupStart'] as int,
          plan.data['backupCount'] as int,
        );
      case PlanKind.backupPartitions:
        final targets =
            (plan.data['targets'] as List).cast<Map<String, Object?>>();
        for (final t in targets) {
          final name = t['name'] as String;
          await saveRead(
            '$name.bin',
            name,
            t['firstLba'] as int,
            t['sizeLbas'] as int,
          );
        }
      default:
        throw StateError('到達しないはずの分岐です');
    }

    final manifest = BackupManifest(
      deviceSerial: serial,
      productDevice: productDevice,
      createdAt: DateTime.now(),
      layoutFingerprint: plan.layoutFingerprint,
      files: entries,
    );
    final manifestFile =
        File('${outDir.path}${Platform.pathSeparator}manifest.json');
    await manifestFile
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
    onProgress?.call('manifest.json を作成しました');
    return manifest;
  }
}
