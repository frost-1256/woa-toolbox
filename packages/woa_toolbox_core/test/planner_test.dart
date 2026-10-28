import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'gpt_image_builder.dart';

const _sector = 512;
const _total = 2048;

Future<({GptTable primary, GptTable backup})> _layout(
    List<SyntheticPartition> partitions) async {
  final image = buildGptImage(
    sectorSize: _sector,
    totalLbas: _total,
    partitions: partitions,
  );
  final both =
      await GptReader.readBoth(MemoryLbaReader(image, sectorSize: _sector));
  return (primary: both.primary, backup: both.backup);
}

const _stockParts = [
  SyntheticPartition('persist', 100, 199),
  SyntheticPartition('super', 200, 999),
  SyntheticPartition('userdata', 1000, 1990),
];

const _woaParts = [
  SyntheticPartition('persist', 100, 199),
  SyntheticPartition('super', 200, 999),
  SyntheticPartition('userdata', 1000, 1490),
  SyntheticPartition('esp', 1491, 1590),
  SyntheticPartition('win', 1591, 1990),
];

void main() {
  const planner = OperationPlanner();

  group('diffGpt', () {
    test('縮小と追加を検出する', () async {
      final a = await _layout(_stockParts);
      final b = await _layout(_woaParts);
      final diff = diffGpt(a.primary, b.primary);
      final byName = {for (final c in diff.changes) c.name: c.kind};
      expect(byName['userdata'], GptChangeKind.resized);
      expect(byName['esp'], GptChangeKind.added);
      expect(byName['win'], GptChangeKind.added);
      expect(diff.changes.length, 3);
    });

    test('同一レイアウトでは空', () async {
      final a = await _layout(_stockParts);
      expect(diffGpt(a.primary, a.primary).isEmpty, isTrue);
    });
  });

  group('OperationPlanner.planBackupGpt', () {
    test('両コピーの LBA 範囲がヘッダーから計算される', () async {
      final a = await _layout(_stockParts);
      final plan = planner.planBackupGpt(
        serial: 'S1',
        primary: a.primary,
        backup: a.backup,
        totalLbas: _total,
      );
      // エントリ配列は 32*128/512 = 8 セクタ。プライマリは 2+8=10、
      // バックアップは末尾 9 セクタ（開始 2048-1-8=2039）。
      expect(plan.data['primaryCount'], 10);
      expect(plan.data['backupStart'], 2039);
      expect(plan.data['backupCount'], 9);
      expect(plan.destructive, isFalse);
    });
  });

  group('OperationPlanner.planBackupPartitions', () {
    test('GPT にある名前だけが対象になる', () async {
      final a = await _layout(_stockParts);
      final plan = planner.planBackupPartitions(
          serial: 'S1', primary: a.primary, names: ['persist']);
      expect(plan.steps.length, 2); // 読み取り + manifest
    });

    test('super は凍結のため拒否される', () async {
      final a = await _layout(_stockParts);
      expect(
        () => planner.planBackupPartitions(
            serial: 'S1', primary: a.primary, names: ['super']),
        throwsArgumentError,
      );
    });

    test('存在しない名前は拒否される', () async {
      final a = await _layout(_stockParts);
      expect(
        () => planner.planBackupPartitions(
            serial: 'S1', primary: a.primary, names: ['modemst1']),
        throwsArgumentError,
      );
    });
  });

  group('OperationPlanner.planRestoreGpt', () {
    test('整合したイメージから破壊的プランと diff が作られる', () async {
      final current = await _layout(_woaParts);
      final restore = await _layout(_stockParts);
      final plan = planner.planRestoreGpt(
        serial: 'S1',
        currentPrimary: current.primary,
        restorePrimary: restore.primary,
        restoreBackup: restore.backup,
        totalLbas: _total,
        restorePath: '/tmp/gpt.bin',
      );
      expect(plan.destructive, isTrue);
      expect(plan.diff!.changes.length, 3);
      expect(plan.steps.length, 7);
      // 書き込み順序: バックアップ側 → プライマリ側（§4.2）。
      final previews = plan.steps.map((s) => s.commandPreview).join('\n');
      expect(previews.indexOf('seek=2039'), lessThan(previews.indexOf('seek=1')));
    });

    test('プライマリとバックアップが食い違うイメージは拒否される', () async {
      final current = await _layout(_woaParts);
      final restoreP = await _layout(_stockParts);
      final otherB = await _layout(_woaParts);
      expect(
        () => planner.planRestoreGpt(
          serial: 'S1',
          currentPrimary: current.primary,
          restorePrimary: restoreP.primary,
          restoreBackup: otherB.backup,
          totalLbas: _total,
          restorePath: '/tmp/gpt.bin',
        ),
        throwsArgumentError,
      );
    });
  });

  group('OperationPlanner.planRestorePartition', () {
    BackupManifest manifestFor(String serial, int sizeBytes) =>
        BackupManifest(
          deviceSerial: serial,
          productDevice: 'spacewar',
          createdAt: DateTime.utc(2026),
          layoutFingerprint: 'x',
          files: [
            BackupFileEntry(
              fileName: 'persist.bin',
              partitionName: 'persist',
              sizeBytes: sizeBytes,
              sha256: 'ab' * 32,
            ),
          ],
        );

    test('別端末のバックアップは拒否される', () async {
      final a = await _layout(_stockParts);
      final m = manifestFor('OTHER', 100 * _sector);
      expect(
        () => planner.planRestorePartition(
          serial: 'S1',
          productDevice: 'spacewar',
          currentPrimary: a.primary,
          manifest: m,
          entry: m.files.single,
        ),
        throwsArgumentError,
      );
    });

    test('サイズ不一致は拒否され、一致すれば通る', () async {
      final a = await _layout(_stockParts);
      final bad = manifestFor('S1', 12345);
      expect(
        () => planner.planRestorePartition(
          serial: 'S1',
          productDevice: 'spacewar',
          currentPrimary: a.primary,
          manifest: bad,
          entry: bad.files.single,
        ),
        throwsArgumentError,
      );
      final good = manifestFor('S1', 100 * _sector);
      final plan = planner.planRestorePartition(
        serial: 'S1',
        productDevice: 'spacewar',
        currentPrimary: a.primary,
        manifest: good,
        entry: good.files.single,
      );
      expect(plan.destructive, isTrue);
    });
  });

  group('OperationPlan.checkBinding', () {
    test('期限切れ・シリアル不一致・レイアウト変化を検出する', () {
      final plan = OperationPlan(
        kind: PlanKind.backupGpt,
        title: 't',
        deviceSerial: 'S1',
        layoutFingerprint: 'fp1',
        steps: const [],
        destructive: false,
        createdAt: DateTime.now().subtract(const Duration(minutes: 11)),
      );
      expect(
        () => plan.checkBinding(serial: 'S1', layoutFingerprint: 'fp1'),
        throwsStateError,
      );
      final fresh = OperationPlan(
        kind: PlanKind.backupGpt,
        title: 't',
        deviceSerial: 'S1',
        layoutFingerprint: 'fp1',
        steps: const [],
        destructive: false,
      );
      expect(
        () => fresh.checkBinding(serial: 'S2', layoutFingerprint: 'fp1'),
        throwsStateError,
      );
      expect(
        () => fresh.checkBinding(serial: 'S1', layoutFingerprint: 'fp2'),
        throwsStateError,
      );
      fresh.checkBinding(serial: 'S1', layoutFingerprint: 'fp1');
    });
  });

  group('BackupExecutor', () {
    test('パーティションバックアップを実行し manifest が一致する', () async {
      final image = buildGptImage(
        sectorSize: _sector,
        totalLbas: _total,
        partitions: _stockParts,
      );
      // persist の中身に目印を置く。
      image.fillRange(100 * _sector, 200 * _sector, 0xAB);
      final reader = MemoryLbaReader(image, sectorSize: _sector);
      final both = await GptReader.readBoth(reader);
      final plan = planner.planBackupPartitions(
          serial: 'S1', primary: both.primary, names: ['persist']);
      final dir = await Directory.systemTemp.createTemp('woa_backup_test');
      addTearDown(() => dir.delete(recursive: true));
      final manifest = await const BackupExecutor().execute(
        plan,
        reader: reader,
        outDir: dir,
        serial: 'S1',
        productDevice: 'spacewar',
        currentFingerprint: both.primary.fingerprint,
      );
      final file = File('${dir.path}${Platform.pathSeparator}persist.bin');
      final bytes = await file.readAsBytes();
      expect(bytes.length, 100 * _sector);
      expect(bytes.every((b) => b == 0xAB), isTrue);
      expect(manifest.files.single.sha256, sha256.convert(bytes).toString());
      final manifestJson = await File(
              '${dir.path}${Platform.pathSeparator}manifest.json')
          .readAsString();
      final decoded = BackupManifest.decode(manifestJson);
      expect(decoded.deviceSerial, 'S1');
      expect(decoded.files.single.partitionName, 'persist');
      expect(
          utf8.decode(bytes, allowMalformed: true).length, bytes.length);
    });
  });
}
