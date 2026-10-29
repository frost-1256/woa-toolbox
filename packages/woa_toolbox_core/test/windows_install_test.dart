import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// DISM / bcdedit / reg をエミュレートするフェイク。
/// Apply-Image のタイミングで win 側の成果物ファイルを生やす。
class _WinRunner implements CommandRunner {
  _WinRunner({required this.winDir, this.wimInfo = _arm64Info});

  final String winDir;
  final String wimInfo;
  final List<String> calls = [];

  static const _arm64Info = '''
Deployment Image Servicing and Management tool
Index : 1
Name : Windows 11 Pro
Architecture : ARM64
''';

  /// 実機 DISM の概要出力（/Index なし）には Architecture 行が無い。
  static const _summaryInfo = '''
Deployment Image Servicing and Management tool
Index : 1
Name : Windows 11 Pro
Description : Windows 11 Pro
Size : 19,094,946,702 bytes
''';

  CommandResult _ok([String out = 'The operation completed successfully.']) =>
      CommandResult(
          exitCode: 0,
          stdoutBytes: Uint8List.fromList(utf8.encode(out)),
          stderrText: '');

  String _join(String base, String rel) =>
      '$base${Platform.pathSeparator}${rel.replaceAll('\\', Platform.pathSeparator)}';

  @override
  Future<CommandResult> run(String executable, List<String> arguments) async {
    final line = '$executable ${arguments.join(' ')}';
    calls.add(line);
    if (executable == 'dism' && arguments.contains('/Get-WimInfo')) {
      // 実機同様、/Index 指定時のみ Architecture を含む詳細を返す。
      final detailed =
          arguments.any((a) => a.startsWith('/Index'));
      return _ok(detailed ? wimInfo : _summaryInfo);
    }
    if (executable == 'dism' &&
        arguments.any((a) => a.startsWith('/Apply-Image'))) {
      // 展開を模擬: winload.efi と bootmgfw.efi を作る。
      final system32 =
          Directory(_join(winDir, r'Windows\System32'));
      await system32.create(recursive: true);
      await File(_join(winDir, r'Windows\System32\winload.efi'))
          .writeAsBytes([1]);
      final efi = Directory(_join(winDir, r'Windows\Boot\EFI'));
      await efi.create(recursive: true);
      await File(_join(winDir, r'Windows\Boot\EFI\bootmgfw.efi'))
          .writeAsBytes([2]);
      return _ok();
    }
    if (executable == 'bcdedit' && arguments.contains('/createstore')) {
      final store = arguments[arguments.indexOf('/createstore') + 1];
      await File(store).create(recursive: true);
      return _ok();
    }
    if (executable == 'bcdedit' &&
        arguments.contains('/create') &&
        arguments.contains('osloader')) {
      return _ok(
          'The entry {11111111-2222-3333-4444-555555555555} was successfully created.');
    }
    return _ok();
  }
}

void main() {
  late Directory tmp;
  late String winDir;
  late String espDir;
  late String wimPath;
  late String packDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('woa_wininstall');
    winDir = '${tmp.path}${Platform.pathSeparator}win';
    espDir = '${tmp.path}${Platform.pathSeparator}esp';
    await Directory(winDir).create();
    await Directory(espDir).create();
    wimPath = '${tmp.path}${Platform.pathSeparator}install.wim';
    await File(wimPath).writeAsBytes([9]);
    packDir = '${tmp.path}${Platform.pathSeparator}pack';
    await Directory(packDir).create();
  });

  tearDown(() => tmp.delete(recursive: true));

  WindowsInstallWizard wizard(CommandRunner runner, {String? info}) =>
      WindowsInstallWizard(
        runner: runner,
        winDir: winDir,
        espDir: espDir,
        wimPath: wimPath,
        driverPackDir: packDir,
        winPartition: 'R:',
        espPartition: 'S:',
        hostIsWindows: true,
      );

  test('正常系: 手順の順序と GUID の伝播、qci2c 修正まで通る', () async {
    final runner = _WinRunner(winDir: winDir);
    final steps = <WinInstallStep>[];
    await wizard(runner).run(onStep: (s, m) => steps.add(s));

    expect(steps.first, WinInstallStep.precondition);
    expect(steps.last, WinInstallStep.done);
    final calls = runner.calls;
    int idx(String part) => calls.indexWhere((c) => c.contains(part));
    expect(idx('/Get-WimInfo'), lessThan(idx('/Apply-Image')));
    expect(idx('/Apply-Image'), lessThan(idx('/createstore')));
    expect(idx('/createstore'), lessThan(idx('/create {bootmgr}')));
    expect(idx('osloader'), lessThan(idx('/Add-Driver')));
    expect(idx('/Add-Driver'), lessThan(idx('reg load')));
    expect(idx('reg load'), lessThan(idx('reg add')));
    expect(idx('reg add'), lessThan(idx('reg unload')));
    // 作成された GUID が /default に伝播している。
    expect(
      calls.any((c) =>
          c.contains('/default {11111111-2222-3333-4444-555555555555}')),
      isTrue,
    );
    // make_bcd.bat と同じ要点が含まれる。
    final joined = calls.join('\n');
    expect(joined, contains('testsigning on'));
    expect(joined, contains('nointegritychecks on'));
    expect(joined, contains('recoveryenabled No'));
    expect(joined, contains(r'\Windows\System32\winload.efi'));
  });

  test('ARM64 でない WIM は展開前に止まる', () async {
    final runner = _WinRunner(
      winDir: winDir,
      wimInfo: 'Index : 1\nArchitecture : x64\n',
    );
    await expectLater(
      wizard(runner).run(onStep: (s, m) {}),
      throwsStateError,
    );
    expect(runner.calls.any((c) => c.contains('/Apply-Image')), isFalse);
  });

  test('Windows 以外のホストでは前提検証で止まる', () async {
    final runner = _WinRunner(winDir: winDir);
    final w = WindowsInstallWizard(
      runner: runner,
      winDir: winDir,
      espDir: espDir,
      wimPath: wimPath,
      hostIsWindows: false,
    );
    await expectLater(w.run(onStep: (s, m) {}), throwsStateError);
    expect(runner.calls, isEmpty);
  });
}
