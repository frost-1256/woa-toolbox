import 'dart:convert';
import 'dart:io';

import '../backup/manifest.dart';
import '../gpt/gpt_reader.dart';
import 'plan.dart';
import 'streaming.dart';

/// バックアップ系プランの実行器（読み取り専用）。
///
/// 実行直前にプランの束縛（シリアル・フィンガープリント・有効期限）を
/// 再検証する。読み取りは [LbaReader] 経由で、受信バイト数は
/// AdbLbaReader が期待サイズと照合する（設計書 §7）。
/// 読み出しはチャンク逐次処理（[writeLbaRangeToFile]）で、全量を
/// メモリに載せない。manifest は全ファイル完了後にのみ書くので、
/// 途中で失敗した回には manifest が残らない。
/// 復元系プランの実行はここでは扱わない。
class BackupExecutor {
  const BackupExecutor();

  /// [plan]（backupGpt / backupPartitions）を実行し、[outDir] に
  /// ファイルと manifest.json を書き、manifest を返す。
  /// [chunkBytes] は 1 回の読み取りの上限（テスト用に差し替え可能）。
  Future<BackupManifest> execute(
    OperationPlan plan, {
    required LbaReader reader,
    required Directory outDir,
    required String serial,
    required String productDevice,
    required String currentFingerprint,
    void Function(String line)? onProgress,
    int chunkBytes = defaultStreamChunkBytes,
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
      final file = File('${outDir.path}${Platform.pathSeparator}$fileName');
      var lastPercent = -1;
      final result = await writeLbaRangeToFile(
        reader,
        startLba,
        count,
        file,
        chunkBytes: chunkBytes,
        onChunk: (done, total) {
          // 進捗は 10% 刻みで間引く（大きなパーティションでも数十行程度）。
          // 100% は刻みに届かなくても必ず 1 回出す。
          final percent = total == 0 ? 100 : (done * 100) ~/ total;
          if (percent >= lastPercent + 10 || percent == 100) {
            lastPercent = percent;
            onProgress?.call('$partitionName を読み取り中: $percent% '
                '(${done ~/ (1024 * 1024)} / ${total ~/ (1024 * 1024)} MiB)');
          }
        },
      );
      entries.add(BackupFileEntry(
        fileName: fileName,
        partitionName: partitionName,
        sizeBytes: result.sizeBytes,
        sha256: result.sha256,
      ));
      onProgress?.call('$fileName を保存しました（${result.sizeBytes} バイト）');
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
    // manifest は .tmp に書いてから rename し、書き込み途中の失敗で
    // 壊れた manifest が最終名に残らないようにする。
    final manifestTmp =
        File('${outDir.path}${Platform.pathSeparator}manifest.json.tmp');
    final manifestFile =
        File('${outDir.path}${Platform.pathSeparator}manifest.json');
    await manifestTmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
    if (await manifestFile.exists()) await manifestFile.delete();
    await manifestTmp.rename(manifestFile.path);
    onProgress?.call('manifest.json を作成しました');
    return manifest;
  }
}
