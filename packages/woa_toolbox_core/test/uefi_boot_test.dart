import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

class BootFakeRunner implements CommandRunner {
  final List<String> invocations = [];

  @override
  Future<CommandResult> run(String executable, List<String> arguments) async {
    final command = ([executable, ...arguments]).join(' ');
    invocations.add(command);
    if (command.contains(' boot ')) {
      return CommandResult(
          exitCode: 0,
          stdoutBytes: Uint8List(0),
          stderrText: 'Sending boot.img\nOKAY');
    }
    return CommandResult(
        exitCode: 0, stdoutBytes: Uint8List(0), stderrText: '');
  }
}

void main() {
  group('BootImage', () {
    test('ANDROID! マジックを検証する', () {
      final good = Uint8List.fromList([
        ...'ANDROID!'.codeUnits,
        ...List.filled(100, 0),
      ]);
      expect(BootImage.validateBytes(good), isNull);
      expect(BootImage.validateBytes(Uint8List.fromList('NOTABOOT'.codeUnits)),
          isNotNull);
      expect(BootImage.validateBytes(Uint8List(4)), isNotNull);
    });
  });

  group('FastbootClient.boot', () {
    test('検証を通ったイメージで fastboot boot を実行する', () async {
      // テスト用の一時ファイルを使う代わりに、validateFile を通すため
      // 実際のファイルを作成する。
      final runner = BootFakeRunner();
      final client = FastbootClient(runner);
      final file = await _tempBootImage();
      final result = await client.boot('serial1', file);
      expect(result.ok, isTrue);
      expect(runner.invocations.single, contains('boot'));
      expect(runner.invocations.single, contains('serial1'));
    });

    test('ブートイメージでなければ実行前に止まる', () async {
      final runner = BootFakeRunner();
      final client = FastbootClient(runner);
      expect(() async => client.boot('serial1', '/nonexistent.img'),
          throwsArgumentError);
      expect(runner.invocations, isEmpty);
    });
  });

  group('GitHub Actions 純関数', () {
    test('最新成功 run をパースする', () {
      final json = jsonDecode('''
      {"workflow_runs": [{"id": 111, "run_number": 51,
        "head_sha": "3fe450a0123456789",
        "html_url": "https://github.com/x/y/actions/runs/111"}]}
      ''') as Map<String, Object?>;
      final run = parseLatestSuccessfulRun(json);
      expect(run?.runNumber, 51);
      expect(run?.headSha, '3fe450a');
      expect(parseLatestSuccessfulRun({'workflow_runs': []}), isNull);
    });

    test('成果物を名前で探し、期限切れを除外する', () {
      final json = jsonDecode('''
      {"artifacts": [
        {"id": 1, "name": "other", "size_in_bytes": 10, "expired": false},
        {"id": 2, "name": "uefi-spacewar", "size_in_bytes": 1200000, "expired": false},
        {"id": 3, "name": "uefi-spacewar", "size_in_bytes": 1, "expired": true}
      ]}
      ''') as Map<String, Object?>;
      final artifact = parseArtifactByName(json, 'uefi-spacewar');
      expect(artifact?.id, 2);
      expect(artifact?.sizeBytes, 1200000);
    });

    test('zip から boot.img を取り出す', () {
      final archive = Archive()
        ..addFile(ArchiveFile(
            'boot.img', 8, Uint8List.fromList('ANDROID!'.codeUnits)));
      final zip = ZipEncoder().encode(archive)!;
      final bytes = extractFileFromZip(Uint8List.fromList(zip), 'boot.img');
      expect(String.fromCharCodes(bytes), 'ANDROID!');
      expect(
          () => extractFileFromZip(Uint8List.fromList(zip), 'missing.img'),
          throwsStateError);
    });
  });
}

int _tempCounter = 0;

Future<String> _tempBootImage() async {
  final path =
      '${Directory.systemTemp.path}/woa_test_boot_${_tempCounter++}.img';
  final bytes = <int>[...'ANDROID!'.codeUnits, ...List.filled(2048, 0)];
  await File(path).writeAsBytes(bytes);
  return path;
}
