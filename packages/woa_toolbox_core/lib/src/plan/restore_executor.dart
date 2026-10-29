import 'dart:io';
import 'dart:typed_data';

import '../device/adb_client.dart';
import '../gpt/gpt.dart';
import '../gpt/gpt_reader.dart';
import 'plan.dart';
import 'streaming.dart';

/// 復元系プランの実行器（設計書 §4.2 / §5.3）。
///
/// GPT 復元は「書き込み前自動バックアップ → バックアップコピー →
/// プライマリコピー（各コピー内はエントリ配列 → ヘッダー）→ sync →
/// 両コピーの再読込検証」の順序を厳密に守る。書き込み途中で失敗したら
/// 自動で続けず、その時点の検証状態を添えて停止する。
class RestoreExecutor {
  RestoreExecutor(this._adb);

  final AdbClient _adb;

  static const _remoteChunk = '/tmp/woa_chunk.bin';

  Future<void> _writeChunk(
    String serial,
    Directory workDir,
    String disk,
    int sectorSize,
    Uint8List chunk,
    int seekLba,
    void Function(String line)? onProgress,
  ) async {
    final file = File(
        '${workDir.path}${Platform.pathSeparator}chunk_${seekLba}_$sectorSize.bin');
    await file.writeAsBytes(chunk);
    await _adb.push(serial, file.path, _remoteChunk);
    final count = chunk.length ~/ sectorSize;
    await _adb.shellText(serial, [
      'dd',
      'if=$_remoteChunk',
      'of=/dev/block/$disk',
      'bs=$sectorSize',
      'seek=$seekLba',
      'count=$count',
      'status=none',
    ]);
    onProgress?.call('LBA $seekLba に $count セクタを書き込みました');
  }

  /// GPT 復元を実行する。[primaryRegion] / [backupRegion] は
  /// バックアップ実行器が作る2ファイル（gpt_primary.bin / gpt_backup.bin）
  /// の中身。[autoBackup] は書き込み直前の現 GPT 保存処理。
  Future<void> executeRestoreGpt(
    OperationPlan plan, {
    required String serial,
    required LbaReader reader,
    required Uint8List primaryRegion,
    required Uint8List backupRegion,
    required GptTable restorePrimary,
    required Directory workDir,
    required Future<void> Function() autoBackup,
    required String currentFingerprint,
    void Function(String line)? onProgress,
  }) async {
    if (plan.kind != PlanKind.restoreGpt) {
      throw ArgumentError('restoreGpt プラン専用です: ${plan.kind}');
    }
    plan.checkBinding(serial: serial, layoutFingerprint: currentFingerprint);
    final disk = plan.data['disk'] as String;
    final totalLbas = plan.data['totalLbas'] as int;
    final entrySectors = plan.data['entrySectors'] as int;
    final sectorSize = restorePrimary.sectorSize;
    final entryLba = restorePrimary.header.partitionEntryLba;
    final entryBytes = restorePrimary.header.entryArrayBytes;

    await workDir.create(recursive: true);
    onProgress?.call('書き込み前の GPT を自動バックアップしています');
    await autoBackup();

    // 領域バイト列を「エントリ配列」と「ヘッダー側」に分割する。
    final primaryHead =
        Uint8List.sublistView(primaryRegion, 0, entryLba * sectorSize);
    final primaryEntries = Uint8List.sublistView(primaryRegion,
        entryLba * sectorSize, entryLba * sectorSize + entryBytes);
    final backupEntries = Uint8List.sublistView(backupRegion, 0, entryBytes);
    final backupHead = Uint8List.sublistView(
        backupRegion, entryBytes, entryBytes + sectorSize);
    if (primaryRegion.length != (entryLba + entrySectors) * sectorSize ||
        backupRegion.length != (entrySectors + 1) * sectorSize) {
      throw StateError('復元イメージの領域サイズが計画と一致しません');
    }

    var writesStarted = false;
    try {
      writesStarted = true;
      // バックアップコピー（エントリ → ヘッダー）。
      await _writeChunk(serial, workDir, disk, sectorSize, backupEntries,
          totalLbas - 1 - entrySectors, onProgress);
      await _writeChunk(serial, workDir, disk, sectorSize, backupHead,
          totalLbas - 1, onProgress);
      // プライマリコピー（エントリ → MBR+ヘッダー）。
      await _writeChunk(serial, workDir, disk, sectorSize, primaryEntries,
          entryLba, onProgress);
      await _writeChunk(
          serial, workDir, disk, sectorSize, primaryHead, 0, onProgress);
      await _adb.shellText(serial, ['sync']);
      onProgress?.call('書き込み完了。両コピーを読み直して検証します');
    } catch (e) {
      if (writesStarted) {
        throw StateError('GPT 書き込みが途中で失敗しました: $e\n'
            '自動では続けません。再読込で現在状態を確認してください'
            '（無事な側のコピーで起動できる設計です）。');
      }
      rethrow;
    }

    final both = await GptReader.readBoth(reader);
    if (!both.consistent ||
        !gptTablesMatch(both.primary, restorePrimary) ||
        both.primary.fingerprint != restorePrimary.fingerprint) {
      throw StateError('書き込み後の検証に失敗しました: 復元イメージと一致しません');
    }
    onProgress?.call('検証 OK: 両コピーが復元イメージと一致しました');
  }

  /// パーティション書き戻しを実行する（設計書 §5.3）。
  ///
  /// ファイル照合と読み戻し検証はチャンク逐次ハッシュ（[hashFileContents] /
  /// [hashLbaRange]）で、全量をメモリに載せない。書き込み経路
  /// （ファイル全体を push して 1 回の dd で書く）は従来どおりで、
  /// 大きなパーティションの書き戻しは端末側 /tmp の制約を受ける。
  Future<void> executeRestorePartition(
    OperationPlan plan, {
    required String serial,
    required LbaReader reader,
    required File localFile,
    required String currentFingerprint,
    void Function(String line)? onProgress,
    int chunkBytes = defaultStreamChunkBytes,
  }) async {
    if (plan.kind != PlanKind.restorePartition) {
      throw ArgumentError('restorePartition プラン専用です: ${plan.kind}');
    }
    plan.checkBinding(serial: serial, layoutFingerprint: currentFingerprint);
    final disk = plan.data['disk'] as String;
    final firstLba = plan.data['firstLba'] as int;
    final sizeLbas = plan.data['sizeLbas'] as int;
    final expectedSha = plan.data['sha256'] as String;

    onProgress?.call('バックアップファイルを照合しています');
    var verifyPercent = -1;
    final check = await hashFileContents(
      localFile,
      onChunk: (done, total) {
        // 照合は大きなファイルでは長時間になるため 10% 刻みで進捗を出す。
        final percent = total == 0 ? 100 : (done * 100) ~/ total;
        if (percent >= verifyPercent + 10 || percent == 100) {
          verifyPercent = percent;
          onProgress?.call('照合中: $percent%');
        }
      },
    );
    if (check.length != sizeLbas * reader.sectorSize) {
      throw StateError('バックアップファイルのサイズが計画と一致しません');
    }
    if (check.sha256 != expectedSha) {
      throw StateError('バックアップファイルの SHA-256 が manifest と一致しません');
    }

    const remote = '/tmp/woa_restore.bin';
    onProgress?.call('バックアップファイルを端末へ送っています');
    await _adb.push(serial, localFile.path, remote);
    await _adb.shellText(serial, [
      'dd',
      'if=$remote',
      'of=/dev/block/$disk',
      'bs=${reader.sectorSize}',
      'seek=$firstLba',
      'count=$sizeLbas',
      'status=none',
    ]);
    await _adb.shellText(serial, ['sync']);
    await _adb.shellText(serial, ['rm', remote]);
    onProgress?.call('書き込み完了。読み戻して検証します');

    var lastPercent = -1;
    final readBackSha = await hashLbaRange(
      reader,
      firstLba,
      sizeLbas,
      chunkBytes: chunkBytes,
      onChunk: (done, total) {
        final percent = total == 0 ? 100 : (done * 100) ~/ total;
        if (percent >= lastPercent + 25 || percent == 100) {
          lastPercent = percent;
          onProgress?.call('読み戻し検証中: $percent%');
        }
      },
    );
    if (readBackSha != expectedSha) {
      throw StateError('書き込み後の検証に失敗しました: SHA-256 が一致しません');
    }
    onProgress?.call('検証 OK: SHA-256 が一致しました');
  }
}
