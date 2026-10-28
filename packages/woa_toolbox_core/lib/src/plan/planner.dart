import '../backup/manifest.dart';
import '../gpt/gpt.dart';
import '../gpt/gpt_diff.dart';
import 'plan.dart';

/// 操作計画の生成（設計書 §2 / §4.2 / §5.2 / §5.3）。
///
/// ここでは「何をするか」の計画だけを作る。実行は別モジュールが担い、
/// 端末側コマンドはここのテンプレートからしか組み立てない（§7）。
class OperationPlanner {
  const OperationPlanner();

  /// spacewar の期待エントリ数（検証用。パーサーには固定しない）。
  static const expectedEntryCount = 32;

  /// 安全凍結: 書き込み・復元の対象に絶対に含めないパーティション。
  static const frozenPartitions = {'super'};

  int _entrySectors(GptTable table) =>
      (table.header.entryArrayBytes + table.sectorSize - 1) ~/
      table.sectorSize;

  /// GPT（プライマリ＋バックアップ両領域）のバックアップ計画。
  OperationPlan planBackupGpt({
    required String serial,
    required GptTable primary,
    required GptTable backup,
    required int totalLbas,
    String disk = 'sda',
  }) {
    final entrySectors = _entrySectors(primary);
    final primaryCount = primary.header.partitionEntryLba + entrySectors;
    final backupStart = totalLbas - 1 - entrySectors;
    final backupCount = entrySectors + 1;
    return OperationPlan(
      kind: PlanKind.backupGpt,
      title: 'GPT バックアップ（$disk）',
      deviceSerial: serial,
      layoutFingerprint: primary.fingerprint,
      destructive: false,
      steps: [
        PlanStep(
          description: 'プライマリ GPT 領域を読む（LBA 0–${primaryCount - 1}）',
          commandPreview:
              'adb exec-out: dd if=/dev/block/$disk bs=${primary.sectorSize} count=$primaryCount',
          kind: StepKind.readDevice,
        ),
        PlanStep(
          description:
              'バックアップ GPT 領域を読む（LBA $backupStart–${totalLbas - 1}）',
          commandPreview:
              'adb exec-out: dd if=/dev/block/$disk bs=${primary.sectorSize} skip=$backupStart count=$backupCount',
          kind: StepKind.readDevice,
        ),
        const PlanStep(
          description: 'manifest.json（SHA-256 付き）を作成する',
          commandPreview: 'PC: backups/<日時>/manifest.json',
          kind: StepKind.writeFile,
        ),
      ],
      data: {
        'disk': disk,
        'primaryStart': 0,
        'primaryCount': primaryCount,
        'backupStart': backupStart,
        'backupCount': backupCount,
        'consistent': gptTablesMatch(primary, backup),
      },
    );
  }

  /// 小物パーティションのバックアップ計画。対象は現在の GPT に存在する
  /// 名前だけに限定する（許可リスト検証、設計書 §7）。
  OperationPlan planBackupPartitions({
    required String serial,
    required GptTable primary,
    required List<String> names,
    String disk = 'sda',
  }) {
    if (names.isEmpty) {
      throw ArgumentError('バックアップ対象が空です');
    }
    final steps = <PlanStep>[];
    final targets = <Map<String, Object?>>[];
    for (final name in names) {
      if (frozenPartitions.contains(name)) {
        throw ArgumentError('$name は安全凍結のため対象にできません');
      }
      final p = primary.partitionByName(name);
      if (p == null) {
        throw ArgumentError('パーティション $name が現在の GPT にありません');
      }
      steps.add(PlanStep(
        description:
            '$name を読む（LBA ${p.firstLba}–${p.lastLba}、${p.sizeLbas} セクタ）',
        commandPreview:
            'adb exec-out: dd if=/dev/block/$disk bs=${primary.sectorSize} skip=${p.firstLba} count=${p.sizeLbas}',
        kind: StepKind.readDevice,
      ));
      targets.add({
        'name': name,
        'firstLba': p.firstLba,
        'sizeLbas': p.sizeLbas,
      });
    }
    steps.add(const PlanStep(
      description: 'manifest.json（SHA-256 付き）を作成する',
      commandPreview: 'PC: backups/<日時>/manifest.json',
      kind: StepKind.writeFile,
    ));
    return OperationPlan(
      kind: PlanKind.backupPartitions,
      title: 'パーティションバックアップ（${names.join(', ')}）',
      deviceSerial: serial,
      layoutFingerprint: primary.fingerprint,
      destructive: false,
      steps: steps,
      data: {'disk': disk, 'targets': targets},
    );
  }

  /// GPT 復元計画（設計書 §4.2）。復元イメージの両コピーの整合性、
  /// セクタサイズ前提、容量範囲を検証し、現在との diff を作る。
  OperationPlan planRestoreGpt({
    required String serial,
    required GptTable currentPrimary,
    required GptTable restorePrimary,
    required GptTable restoreBackup,
    required int totalLbas,
    required String restorePath,
    String disk = 'sda',
  }) {
    if (!gptTablesMatch(restorePrimary, restoreBackup)) {
      throw ArgumentError('復元イメージのプライマリとバックアップが一致しません');
    }
    if (restorePrimary.sectorSize != currentPrimary.sectorSize) {
      throw ArgumentError('復元イメージのセクタサイズ前提が現在の端末と異なります');
    }
    for (final p in restorePrimary.partitions) {
      if (p.lastLba >= totalLbas) {
        throw ArgumentError(
            'パーティション ${p.name} がディスク容量を超えています（${p.lastLba} >= $totalLbas）');
      }
    }
    final warnings = <String>[];
    if (restorePrimary.header.numberOfPartitionEntries !=
        expectedEntryCount) {
      warnings.add('復元イメージのエントリ数が想定 ($expectedEntryCount) と異なります: '
          '${restorePrimary.header.numberOfPartitionEntries}');
    }
    if (restorePrimary.header.diskGuid != currentPrimary.header.diskGuid) {
      warnings.add('ディスク GUID が変わります: '
          '${currentPrimary.header.diskGuid} → ${restorePrimary.header.diskGuid}');
    }
    final entrySectors = _entrySectors(restorePrimary);
    final bs = restorePrimary.sectorSize;
    final backupEntriesLba = totalLbas - 1 - entrySectors;
    return OperationPlan(
      kind: PlanKind.restoreGpt,
      title: 'GPT 復元（$disk）',
      deviceSerial: serial,
      layoutFingerprint: currentPrimary.fingerprint,
      destructive: true,
      diff: diffGpt(currentPrimary, restorePrimary),
      warnings: warnings,
      steps: [
        const PlanStep(
          description: '現在の GPT（両コピー）を復旧用に自動バックアップする',
          commandPreview: 'PC: backups/<日時>-pre-restore/',
          kind: StepKind.writeFile,
        ),
        PlanStep(
          description: 'バックアップ GPT のエントリ配列を書き込む',
          commandPreview:
              'adb: dd of=/dev/block/$disk bs=$bs seek=$backupEntriesLba',
          kind: StepKind.writeDevice,
        ),
        PlanStep(
          description: 'バックアップ GPT のヘッダーを書き込む',
          commandPreview:
              'adb: dd of=/dev/block/$disk bs=$bs seek=${totalLbas - 1}',
          kind: StepKind.writeDevice,
        ),
        PlanStep(
          description: 'プライマリ GPT のエントリ配列を書き込む',
          commandPreview:
              'adb: dd of=/dev/block/$disk bs=$bs seek=${restorePrimary.header.partitionEntryLba}',
          kind: StepKind.writeDevice,
        ),
        PlanStep(
          description: 'プライマリ GPT のヘッダーを書き込む',
          commandPreview: 'adb: dd of=/dev/block/$disk bs=$bs seek=1',
          kind: StepKind.writeDevice,
        ),
        const PlanStep(
          description: '端末側で同期する',
          commandPreview: 'adb shell: sync',
          kind: StepKind.writeDevice,
        ),
        const PlanStep(
          description: '両コピーを読み直して CRC と相互整合性を検証する',
          commandPreview: 'adb exec-out: dd if=/dev/block/sda …（再読込）',
          kind: StepKind.verify,
        ),
      ],
      data: {
        'disk': disk,
        'restorePath': restorePath,
        'totalLbas': totalLbas,
        'entrySectors': entrySectors,
      },
    );
  }

  /// 小物パーティションの書き戻し計画（設計書 §5.3）。
  /// バックアップを取得した端末にだけ復元できることを検証する。
  OperationPlan planRestorePartition({
    required String serial,
    required String productDevice,
    required GptTable currentPrimary,
    required BackupManifest manifest,
    required BackupFileEntry entry,
    String disk = 'sda',
  }) {
    if (manifest.deviceSerial != serial) {
      throw ArgumentError('このバックアップは別の端末のものです（シリアル不一致）');
    }
    if (manifest.productDevice != productDevice) {
      throw ArgumentError('このバックアップは別の製品のものです');
    }
    if (frozenPartitions.contains(entry.partitionName)) {
      throw ArgumentError('${entry.partitionName} は安全凍結のため復元できません');
    }
    final p = currentPrimary.partitionByName(entry.partitionName);
    if (p == null) {
      throw ArgumentError(
          'パーティション ${entry.partitionName} が現在の GPT にありません');
    }
    final sizeBytes = p.sizeLbas * currentPrimary.sectorSize;
    if (sizeBytes != entry.sizeBytes) {
      throw ArgumentError('サイズが一致しません: バックアップ ${entry.sizeBytes} バイト / '
          '現在 $sizeBytes バイト');
    }
    return OperationPlan(
      kind: PlanKind.restorePartition,
      title: 'パーティション復元（${entry.partitionName}）',
      deviceSerial: serial,
      layoutFingerprint: currentPrimary.fingerprint,
      destructive: true,
      steps: [
        PlanStep(
          description: 'バックアップファイルを端末へ送る',
          commandPreview: 'adb push ${entry.fileName} /tmp/woa_restore.bin',
          kind: StepKind.writeDevice,
        ),
        PlanStep(
          description:
              '${entry.partitionName} に書き込む（LBA ${p.firstLba}–${p.lastLba}）',
          commandPreview:
              'adb shell: dd if=/tmp/woa_restore.bin of=/dev/block/$disk bs=${currentPrimary.sectorSize} seek=${p.firstLba} count=${p.sizeLbas}',
          kind: StepKind.writeDevice,
        ),
        const PlanStep(
          description: '端末側で同期する',
          commandPreview: 'adb shell: sync',
          kind: StepKind.writeDevice,
        ),
        PlanStep(
          description: '読み戻して SHA-256 がバックアップと一致するか検証する',
          commandPreview:
              'adb exec-out: dd if=/dev/block/$disk …（${entry.sha256.substring(0, 12)}… と比較）',
          kind: StepKind.verify,
        ),
      ],
      data: {
        'disk': disk,
        'partition': entry.partitionName,
        'firstLba': p.firstLba,
        'sizeLbas': p.sizeLbas,
        'sha256': entry.sha256,
      },
    );
  }
}
