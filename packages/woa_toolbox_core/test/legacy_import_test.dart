import 'dart:io';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'gpt_image_builder.dart';

void main() {
  test('実機 stock GPT フィクスチャを取り込み、復元プランが作れる', () async {
    final dump = await File('test/fixtures/gpt_sda_stock.bin').readAsBytes();
    const totalLbas = 29644800;
    final dir = await Directory.systemTemp.createTemp('woa_legacy');
    addTearDown(() => dir.delete(recursive: true));

    final manifest = await LegacyImport.importSet(
      gptDump: dump,
      outDir: dir,
      deviceSerial: 'SERIAL1',
      productDevice: 'spacewar',
      sectorSize: 4096,
      totalLbas: totalLbas,
    );
    expect(manifest.files.length, 2);

    // 取り込んだ2ファイルをパースし直すと、両コピーが整合する。
    final sep = Platform.pathSeparator;
    final primaryBytes =
        await File('${dir.path}${sep}gpt_primary.bin').readAsBytes();
    final backupBytes =
        await File('${dir.path}${sep}gpt_backup.bin').readAsBytes();
    final rp = GptParser.parsePrimary(primaryBytes, sectorSize: 4096);
    final rb = GptParser.parseBackup(backupBytes,
        sectorSize: 4096, totalLbas: totalLbas);
    expect(gptTablesMatch(rp, rb), isTrue);
    expect(rp.partitions.length, 10);
    expect(rp.fingerprint, manifest.layoutFingerprint);

    // 現在のテーブルは 4096 セクタの小さな合成イメージから取る
    // （容量チェックは planner に渡す実機 totalLbas で行われる）。
    final currentImage = buildGptImage(
      sectorSize: 4096,
      totalLbas: 4096,
      partitions: const [
        SyntheticPartition('persist', 100, 199),
        SyntheticPartition('userdata', 1000, 1490),
        SyntheticPartition('esp', 1491, 1590),
        SyntheticPartition('win', 1591, 1990),
      ],
    );
    final current = await GptReader.readBoth(
        MemoryLbaReader(currentImage, sectorSize: 4096));
    final plan = const OperationPlanner().planRestoreGpt(
      serial: 'SERIAL1',
      currentPrimary: current.primary,
      restorePrimary: rp,
      restoreBackup: rb,
      totalLbas: totalLbas,
      restorePath: dir.path,
    );
    expect(plan.destructive, isTrue);
    // esp / win が消え、userdata が広がる差分が見える。
    final kinds = {for (final c in plan.diff!.changes) c.name: c.kind};
    expect(kinds['esp'], GptChangeKind.removed);
    expect(kinds['win'], GptChangeKind.removed);
    expect(kinds['userdata'], GptChangeKind.resized);
  });

  test('パーティションファイルの取り込みとサイズ不一致の拒否', () async {
    final image = buildGptImage(
      sectorSize: 512,
      totalLbas: 2048,
      partitions: const [SyntheticPartition('persist', 100, 199)],
    );
    final both =
        await GptReader.readBoth(MemoryLbaReader(image, sectorSize: 512));
    final dir = await Directory.systemTemp.createTemp('woa_legacy_part');
    addTearDown(() => dir.delete(recursive: true));
    final good = File('${dir.path}${Platform.pathSeparator}src_good.bin');
    await good.writeAsBytes(List.filled(100 * 512, 7));
    final manifest = await LegacyImport.importSet(
      partitionFiles: {'persist': good},
      outDir: Directory('${dir.path}${Platform.pathSeparator}out'),
      deviceSerial: 'S1',
      productDevice: 'spacewar',
      sectorSize: 512,
      totalLbas: 2048,
      sdaPrimary: both.primary,
    );
    expect(manifest.files.single.partitionName, 'persist');
    expect(manifest.files.single.sizeBytes, 100 * 512);

    final bad = File('${dir.path}${Platform.pathSeparator}src_bad.bin');
    await bad.writeAsBytes(List.filled(10, 7));
    expect(
      () => LegacyImport.importSet(
        partitionFiles: {'persist': bad},
        outDir: Directory('${dir.path}${Platform.pathSeparator}out2'),
        deviceSerial: 'S1',
        productDevice: 'spacewar',
        sectorSize: 512,
        totalLbas: 2048,
        sdaPrimary: both.primary,
      ),
      throwsArgumentError,
    );
  });
}
