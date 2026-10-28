import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'gpt_image_builder.dart';

class _Runner implements CommandRunner {
  final List<String> calls = [];

  @override
  Future<CommandResult> run(String executable, List<String> arguments) async {
    calls.add(arguments.join(' '));
    return CommandResult(
        exitCode: 0, stdoutBytes: Uint8List(0), stderrText: '');
  }
}

Future<GptTable> _table(List<SyntheticPartition> parts) async {
  final image =
      buildGptImage(sectorSize: 512, totalLbas: 2048, partitions: parts);
  final both =
      await GptReader.readBoth(MemoryLbaReader(image, sectorSize: 512));
  return both.primary;
}

const _woaParts = [
  SyntheticPartition('persist', 100, 199),
  SyntheticPartition('userdata', 1000, 1490),
  SyntheticPartition('esp', 1491, 1590),
  SyntheticPartition('win', 1591, 1990),
];

const _stockParts = [
  SyntheticPartition('persist', 100, 199),
  SyntheticPartition('userdata', 1000, 1990),
];

void main() {
  test('正常系: ステップが順に進み sideload まで到達する', () async {
    final zip = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}lineage.zip');
    await zip.writeAsBytes([1, 2, 3]);
    addTearDown(() => zip.delete());

    final runner = _Runner();
    var probeCalls = 0;
    Future<List<ToolboxDevice>> probe() async {
      probeCalls++;
      // 1: 前提検証 (recovery) / 2: 再起動後の確認 (recovery) /
      // 3: sideload 待ち1回目 (recovery) / 4: sideload 待ち2回目 (sideload)
      final mode =
          probeCalls >= 4 ? DeviceMode.sideload : DeviceMode.recovery;
      return [ToolboxDevice(serial: 'S1', mode: mode)];
    }

    var restored = false;
    final steps = <ReturnStep>[];
    final wizard = ReturnToAndroidWizard(
      adb: AdbClient(runner),
      probe: probe,
      restoreGpt: (onProgress) async => restored = true,
      pollInterval: const Duration(milliseconds: 1),
    );
    await wizard.run(
      serial: 'S1',
      currentPrimary: await _table(_woaParts),
      restorePrimary: await _table(_stockParts),
      lineageZipPath: zip.path,
      onStep: (step, message) => steps.add(step),
    );
    expect(restored, isTrue);
    expect(steps.first, ReturnStep.precondition);
    expect(steps.last, ReturnStep.done);
    expect(steps, contains(ReturnStep.awaitSideload));
    expect(runner.calls.any((c) => c.contains('reboot recovery')), isTrue);
    expect(runner.calls.any((c) => c.contains('sideload')), isTrue);
  });

  test('現在の GPT が WoA でなければ復元せずに止まる', () async {
    final zip = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}lineage2.zip');
    await zip.writeAsBytes([1]);
    addTearDown(() => zip.delete());

    var restored = false;
    final wizard = ReturnToAndroidWizard(
      adb: AdbClient(_Runner()),
      probe: () async =>
          [const ToolboxDevice(serial: 'S1', mode: DeviceMode.recovery)],
      restoreGpt: (onProgress) async => restored = true,
      pollInterval: const Duration(milliseconds: 1),
    );
    await expectLater(
      wizard.run(
        serial: 'S1',
        currentPrimary: await _table(_stockParts),
        restorePrimary: await _table(_stockParts),
        lineageZipPath: zip.path,
        onStep: (step, message) {},
      ),
      throwsStateError,
    );
    expect(restored, isFalse);
  });

  test('復元先が WoA レイアウトなら止まる', () async {
    final zip = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}lineage3.zip');
    await zip.writeAsBytes([1]);
    addTearDown(() => zip.delete());

    final wizard = ReturnToAndroidWizard(
      adb: AdbClient(_Runner()),
      probe: () async =>
          [const ToolboxDevice(serial: 'S1', mode: DeviceMode.recovery)],
      restoreGpt: (onProgress) async {},
      pollInterval: const Duration(milliseconds: 1),
    );
    await expectLater(
      wizard.run(
        serial: 'S1',
        currentPrimary: await _table(_woaParts),
        restorePrimary: await _table(_woaParts),
        lineageZipPath: zip.path,
        onStep: (step, message) {},
      ),
      throwsStateError,
    );
  });
}
