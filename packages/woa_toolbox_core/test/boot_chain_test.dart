import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// fastboot devices は最初の [appearAfterCalls] 回は空を返し、
/// それ以降は対象シリアルを返すフェイク。
class ChainFakeRunner implements CommandRunner {
  ChainFakeRunner({this.appearAfterCalls = 2});

  final int appearAfterCalls;
  final List<String> invocations = [];
  int _fastbootDeviceCalls = 0;

  @override
  Future<CommandResult> run(String executable, List<String> arguments) async {
    final command = ([executable, ...arguments]).join(' ');
    invocations.add(command);
    CommandResult ok([String stdout = '', String stderr = '']) =>
        CommandResult(
          exitCode: 0,
          stdoutBytes: Uint8List.fromList(utf8.encode(stdout)),
          stderrText: stderr,
        );
    if (command == 'adb devices -l') {
      return ok('List of devices attached\n');
    }
    if (command == 'fastboot devices') {
      _fastbootDeviceCalls++;
      if (_fastbootDeviceCalls > appearAfterCalls) {
        return ok('SERIAL1\tfastboot\n');
      }
      return ok('');
    }
    if (command.contains(' boot ')) {
      return ok('', 'Sending boot.img\nOKAY');
    }
    return ok();
  }
}

Future<String> _tempBootImage() async {
  final file = File(
      '${Directory.systemTemp.path}/woa_chain_test_${DateTime.now().microsecondsSinceEpoch}.img');
  await file.writeAsBytes(
      [...'ANDROID!'.codeUnits, ...List.filled(2048, 0)]);
  return file.path;
}

void main() {
  group('RecoveryBootChain.bootFromRecovery', () {
    test('再起動 → fastboot 検出 → boot の順で実行する', () async {
      final runner = ChainFakeRunner();
      final chain = RecoveryBootChain(
        runner,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 10),
      );
      final image = await _tempBootImage();
      final progress = <String>[];
      await chain.bootFromRecovery(
        serial: 'SERIAL1',
        imagePath: image,
        onProgress: progress.add,
      );
      final rebootAt =
          runner.invocations.indexWhere((c) => c.contains('reboot bootloader'));
      final bootAt =
          runner.invocations.indexWhere((c) => c.contains(' boot '));
      expect(rebootAt, greaterThanOrEqualTo(0));
      expect(bootAt, greaterThan(rebootAt));
      expect(progress.last, contains('UEFI'));
    });

    test('不正なイメージは再起動前に止まる', () async {
      final runner = ChainFakeRunner();
      final chain = RecoveryBootChain(runner);
      expect(
        () async => chain.bootFromRecovery(
            serial: 'SERIAL1', imagePath: '/nonexistent.img'),
        throwsArgumentError,
      );
      // 検証はファイル読み取りのみで、コマンドは一切実行されない。
      expect(runner.invocations, isEmpty);
    });

    test('fastboot で検出されなければタイムアウトする', () async {
      final runner = ChainFakeRunner(appearAfterCalls: 1 << 30);
      final chain = RecoveryBootChain(
        runner,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 60),
      );
      final image = await _tempBootImage();
      await expectLater(
        chain.bootFromRecovery(serial: 'SERIAL1', imagePath: image),
        throwsStateError,
      );
      expect(runner.invocations.where((c) => c.contains(' boot ')), isEmpty);
    });
  });
}
