import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'gpt_image_builder.dart';

const _sector = 512;
const _total = 2048;

/// メモリ上のディスクを持つフェイク端末。exec-out dd（読み）、
/// push + shell dd（書き）、shell sync/rm をエミュレートする。
class FakeDeviceRunner implements CommandRunner {
  FakeDeviceRunner(this.disk);

  final Uint8List disk;
  final Map<String, Uint8List> files = {};
  final List<String> invocations = [];

  int _arg(List<String> args, String key) =>
      int.parse(args.firstWhere((a) => a.startsWith('$key=')).split('=')[1]);

  @override
  Future<CommandResult> run(String executable, List<String> arguments) async {
    invocations.add(([executable, ...arguments]).join(' '));
    CommandResult ok([Uint8List? out]) => CommandResult(
        exitCode: 0, stdoutBytes: out ?? Uint8List(0), stderrText: '');

    if (arguments.contains('exec-out')) {
      final skip = _arg(arguments, 'skip');
      final count = _arg(arguments, 'count');
      return ok(Uint8List.sublistView(
          disk, skip * _sector, (skip + count) * _sector));
    }
    if (arguments.contains('push')) {
      final local = arguments[arguments.length - 2];
      final remote = arguments.last;
      files[remote] = await File(local).readAsBytes();
      return ok();
    }
    if (arguments.contains('shell')) {
      final cmd = arguments.sublist(arguments.indexOf('shell') + 1);
      if (cmd.first == 'dd') {
        final src = files[cmd.firstWhere((a) => a.startsWith('if=')).split('=')[1]];
        final seek = _arg(cmd, 'seek');
        final count = _arg(cmd, 'count');
        disk.setRange(
            seek * _sector, (seek + count) * _sector, src!.take(count * _sector));
        return ok();
      }
      return ok(); // sync / rm
    }
    return ok();
  }
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

  test('GPT 復元の往復: WoA レイアウトを stock に書き戻せる', () async {
    // 復元イメージ（stock）の両領域を先に用意する。
    final stockImage = buildGptImage(
        sectorSize: _sector, totalLbas: _total, partitions: _stockParts);
    final stockReader = MemoryLbaReader(stockImage, sectorSize: _sector);
    final stockBoth = await GptReader.readBoth(stockReader);
    final backupPlan = planner.planBackupGpt(
      serial: 'S1',
      primary: stockBoth.primary,
      backup: stockBoth.backup,
      totalLbas: _total,
    );
    final dir = await Directory.systemTemp.createTemp('woa_restore_test');
    addTearDown(() => dir.delete(recursive: true));
    final manifest = await const BackupExecutor().execute(
      backupPlan,
      reader: stockReader,
      outDir: Directory('${dir.path}${Platform.pathSeparator}stock_backup'),
      serial: 'S1',
      productDevice: 'spacewar',
      currentFingerprint: stockBoth.primary.fingerprint,
    );
    expect(manifest.files.length, 2);

    // 端末側は WoA レイアウトで動いている。
    final deviceDisk = buildGptImage(
        sectorSize: _sector, totalLbas: _total, partitions: _woaParts);
    final runner = FakeDeviceRunner(deviceDisk);
    final adb = AdbClient(runner);
    final reader = AdbLbaReader(
      adb,
      'S1',
      const BlockDeviceInfo(
          logicalSectorSize: _sector,
          totalBytes: _total * _sector,
          totalLbas: _total),
    );
    final currentBoth = await GptReader.readBoth(reader);

    final backupDir =
        Directory('${dir.path}${Platform.pathSeparator}stock_backup');
    final primaryRegion = await File(
            '${backupDir.path}${Platform.pathSeparator}gpt_primary.bin')
        .readAsBytes();
    final backupRegion = await File(
            '${backupDir.path}${Platform.pathSeparator}gpt_backup.bin')
        .readAsBytes();

    final plan = planner.planRestoreGpt(
      serial: 'S1',
      currentPrimary: currentBoth.primary,
      restorePrimary: stockBoth.primary,
      restoreBackup: stockBoth.backup,
      totalLbas: _total,
      restorePath: backupDir.path,
    );
    var autoBackupRan = false;
    await RestoreExecutor(adb).executeRestoreGpt(
      plan,
      serial: 'S1',
      reader: reader,
      primaryRegion: primaryRegion,
      backupRegion: backupRegion,
      restorePrimary: stockBoth.primary,
      workDir: Directory('${dir.path}${Platform.pathSeparator}work'),
      autoBackup: () async => autoBackupRan = true,
      currentFingerprint: currentBoth.primary.fingerprint,
    );
    expect(autoBackupRan, isTrue);

    // 書き込み順序: バックアップ側 (seek=2039) がプライマリ (seek=0) より先。
    final ddSeeks = runner.invocations
        .where((c) => c.contains('shell dd'))
        .map((c) => int.parse(c.split('seek=')[1].split(' ')[0]))
        .toList();
    expect(ddSeeks, [2039, 2047, 2, 0]);

    final after = await GptReader.readBoth(reader);
    expect(after.consistent, isTrue);
    expect(after.primary.fingerprint, stockBoth.primary.fingerprint);
  });

  test('パーティション書き戻しの往復と改ざん検出', () async {
    final image = buildGptImage(
        sectorSize: _sector, totalLbas: _total, partitions: _stockParts);
    image.fillRange(100 * _sector, 200 * _sector, 0xCD);
    final runner = FakeDeviceRunner(image);
    final adb = AdbClient(runner);
    final reader = AdbLbaReader(
      adb,
      'S1',
      const BlockDeviceInfo(
          logicalSectorSize: _sector,
          totalBytes: _total * _sector,
          totalLbas: _total),
    );
    final both = await GptReader.readBoth(reader);

    // バックアップ取得 → 端末側を壊す → 書き戻す。
    final dir = await Directory.systemTemp.createTemp('woa_part_restore');
    addTearDown(() => dir.delete(recursive: true));
    final backupPlan = planner.planBackupPartitions(
        serial: 'S1', primary: both.primary, names: ['persist']);
    final manifest = await const BackupExecutor().execute(
      backupPlan,
      reader: reader,
      outDir: dir,
      serial: 'S1',
      productDevice: 'spacewar',
      currentFingerprint: both.primary.fingerprint,
    );
    image.fillRange(100 * _sector, 200 * _sector, 0x00);

    final restorePlan = planner.planRestorePartition(
      serial: 'S1',
      productDevice: 'spacewar',
      currentPrimary: both.primary,
      manifest: manifest,
      entry: manifest.files.single,
    );
    await RestoreExecutor(adb).executeRestorePartition(
      restorePlan,
      serial: 'S1',
      reader: reader,
      localFile: File('${dir.path}${Platform.pathSeparator}persist.bin'),
      currentFingerprint: both.primary.fingerprint,
    );
    expect(
        image.sublist(100 * _sector, 200 * _sector).every((b) => b == 0xCD),
        isTrue);
  });
}
