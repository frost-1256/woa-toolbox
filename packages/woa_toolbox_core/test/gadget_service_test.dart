import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// shell コマンドを記録し、cat の読み戻しには状態に沿って答えるフェイク。
class GadgetFakeRunner implements CommandRunner {
  final List<String> commands = [];
  bool failStrictStep = false;
  bool failRoStep = false;

  @override
  Future<CommandResult> run(String executable, List<String> args) async {
    final command = args.last;
    commands.add(command);
    CommandResult ok([String out = '']) => CommandResult(
          exitCode: 0,
          stdoutBytes: Uint8List.fromList(utf8.encode(out)),
          stderrText: '',
        );
    CommandResult ng() => CommandResult(
        exitCode: 1, stdoutBytes: Uint8List(0), stderrText: 'error');
    if (failStrictStep && command.startsWith('mkdir')) return ng();
    if (failRoStep && command.contains('lun.0/ro')) return ng();
    if (command.contains('lun.0/file') && command.startsWith('cat')) {
      final enabled =
          commands.any((c) => c.contains('echo /dev/block/sda >'));
      return ok(enabled ? '/dev/block/sda\n' : '\n');
    }
    if (command == 'cat /config/usb_gadget/g1/UDC') {
      final bound = commands.any((c) => c.contains('a600000.dwc3'));
      return ok(bound ? 'a600000.dwc3\n' : '\n');
    }
    return ok();
  }
}

void main() {
  group('GadgetService', () {
    test('有効化は ms_on.sh と同じ順序でコマンドを発行する', () async {
      final runner = GadgetFakeRunner();
      final service = GadgetService(runner);
      await service.enableMassStorage('serial1');
      expect(runner.commands.first, 'umount /data 2>/dev/null');
      expect(
        runner.commands,
        contains('mkdir -p /config/usb_gadget/g1/functions/mass_storage.0'),
      );
      final lunIndex = runner.commands.indexWhere(
          (c) => c.contains('echo /dev/block/sda >') && c.contains('lun.0/file'));
      final udcIndex =
          runner.commands.indexWhere((c) => c.startsWith("sh -c 'echo >"));
      expect(lunIndex, greaterThan(0));
      expect(udcIndex, greaterThan(lunIndex),
          reason: 'UDC の張り直しは LUN 設定の後');
    });

    test('許可リスト外のデバイスは拒否する', () async {
      final service = GadgetService(GadgetFakeRunner());
      expect(
        () => service.enableMassStorage('serial1',
            blockDevice: '/dev/block/sdb'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('厳密ステップの失敗は例外にする', () async {
      final runner = GadgetFakeRunner()..failStrictStep = true;
      final service = GadgetService(runner);
      expect(
        () => service.enableMassStorage('serial1'),
        throwsA(isA<StateError>()),
      );
    });

    test('LUN 属性 (ro) の書き込み失敗は許容する（ms_on.sh の意味論）', () async {
      final runner = GadgetFakeRunner()..failRoStep = true;
      final service = GadgetService(runner);
      await service.enableMassStorage('serial1');
      expect(await service.massStorageState('serial1'), MassStorageState.on);
    });

    test('状態読み取り: LUN が空なら off、割り当て済みなら on', () async {
      final runner = GadgetFakeRunner();
      final service = GadgetService(runner);
      expect(await service.massStorageState('serial1'), MassStorageState.off);
      await service.enableMassStorage('serial1');
      expect(await service.massStorageState('serial1'), MassStorageState.on);
    });
  });
}
