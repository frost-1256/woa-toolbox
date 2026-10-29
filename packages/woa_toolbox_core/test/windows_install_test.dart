import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// DISM / bcdboot / bcdedit / reg をエミュレートするフェイク。
/// Apply-Image のタイミングで win 側の成果物ファイルを生やし、
/// bcdboot で ESP に BCD を作る。reg は SysprepStatus と qci2c の
/// 状態だけを持つ（トラブルシューターの読み書きを通すため）。
class _WinRunner implements CommandRunner {
  _WinRunner(
      {required this.winDir, required this.espDir, this.wimInfo = _arm64Info});

  final String winDir;
  final String espDir;
  final String wimInfo;
  final List<String> calls = [];

  int generalizationState = 6;
  int qci2cStart = 3;
  bool bcdRecoveryOff = false;
  bool bcdIgnoreFailures = false;

  /// bcdboot の失敗を仕掛けるためのノブ。
  int bcdbootAttempts = 0;
  bool bcdbootAlwaysFails = false;
  bool bcdbootFailsFirst = false;

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

  CommandResult _fail() => CommandResult(
      exitCode: 1,
      stdoutBytes: Uint8List.fromList(utf8.encode('ERROR')),
      stderrText:
          'ERROR: The system was unable to find the specified registry key or value.');

  String _join(String base, String rel) =>
      '$base${Platform.pathSeparator}${rel.replaceAll('\\', Platform.pathSeparator)}';

  @override
  Future<CommandResult> run(String executable, List<String> arguments) async {
    final line = '$executable ${arguments.join(' ')}';
    calls.add(line);
    if (executable == 'dism' && arguments.contains('/Get-WimInfo')) {
      // 実機同様、/Index 指定時のみ Architecture を含む詳細を返す。
      final detailed = arguments.any((a) => a.startsWith('/Index'));
      return _ok(detailed ? wimInfo : _summaryInfo);
    }
    if (executable == 'dism' &&
        arguments.any((a) => a.startsWith('/Apply-Image'))) {
      // 展開を模擬: winload.efi / bootmgfw.efi / SYSTEM ハイブを作る。
      final system32 = Directory(_join(winDir, r'Windows\System32'));
      await system32.create(recursive: true);
      await File(_join(winDir, r'Windows\System32\winload.efi'))
          .writeAsBytes([1]);
      final config = Directory(_join(winDir, r'Windows\System32\config'));
      await config.create(recursive: true);
      await File(_join(winDir, r'Windows\System32\config\SYSTEM'))
          .writeAsBytes([5]);
      final efi = Directory(_join(winDir, r'Windows\Boot\EFI'));
      await efi.create(recursive: true);
      await File(_join(winDir, r'Windows\Boot\EFI\bootmgfw.efi'))
          .writeAsBytes([2]);
      return _ok();
    }
    if (executable == 'bcdboot') {
      bcdbootAttempts++;
      if (bcdbootAlwaysFails) return _fail();
      if (bcdbootFailsFirst && bcdbootAttempts == 1) return _fail();
      final msBoot = Directory(_join(espDir, r'EFI\Microsoft\Boot'));
      await msBoot.create(recursive: true);
      await File(_join(espDir, r'EFI\Microsoft\Boot\BCD')).writeAsBytes([3]);
      return _ok();
    }
    if (executable == 'bcdedit' && arguments.contains('/enum')) {
      return _ok('''
Windows Boot Loader
-------------------
identifier              {default}
device                  partition=R:
path                    \\Windows\\System32\\winload.efi
osdevice                partition=R:
recoveryenabled         ${bcdRecoveryOff ? 'No' : 'Yes'}
${bcdIgnoreFailures ? 'bootstatuspolicy        IgnoreAllFailures' : ''}
''');
    }
    if (executable == 'bcdedit' && arguments.contains('/set')) {
      final name = arguments[arguments.length - 2];
      final value = arguments[arguments.length - 1];
      if (name == 'recoveryenabled' && value == 'No') bcdRecoveryOff = true;
      if (name == 'bootstatuspolicy' && value == 'IgnoreAllFailures') {
        bcdIgnoreFailures = true;
      }
      return _ok();
    }
    if (executable == 'reg') return _reg(arguments);
    return _ok();
  }

  CommandResult _reg(List<String> a) {
    final op = a[0];
    if (op == 'load' || op == 'unload') return _ok();
    final keyName = a[1];
    bool isSysprep() => keyName.endsWith(r'Setup\Status\SysprepStatus');
    bool isQci2c() => keyName.endsWith(r'Services\qci2c');
    if (op == 'query' && a.contains('/v')) {
      final name = a[a.indexOf('/v') + 1];
      // 出力ヘッダーは実 reg.exe と同じ正規化形式（HKEY_LOCAL_MACHINE）。
      final displayKey = keyName.replaceFirst(r'HKLM\', r'HKEY_LOCAL_MACHINE\');
      if (isSysprep() &&
          (name == 'GeneralizationState' || name == 'CleanupState')) {
        final v = name == 'GeneralizationState'
            ? generalizationState
            : 2; // CleanupState は修復後の値で応答（検証を通す）
        return _ok(
            '\n$displayKey\n    $name    REG_DWORD    0x${v.toRadixString(16)}\n');
      }
      if (isQci2c() && name == 'Start') {
        return _ok(
            '\n$displayKey\n    Start    REG_DWORD    0x${qci2cStart.toRadixString(16)}\n');
      }
      return _fail();
    }
    if (op == 'query') return _fail(); // Enum 等は存在しない
    if (op == 'add') {
      final name = a[a.indexOf('/v') + 1];
      final data = int.parse(a[a.indexOf('/d') + 1]);
      if (isSysprep() && name == 'GeneralizationState') {
        generalizationState = data;
      }
      if (isQci2c() && name == 'Start') qci2cStart = data;
      return _ok();
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

  WindowsInstallWizard wizard(CommandRunner runner) => WindowsInstallWizard(
        runner: runner,
        winDir: winDir,
        espDir: espDir,
        wimPath: wimPath,
        driverPackDir: packDir,
        winPartition: 'R:',
        espPartition: 'S:',
        hostIsWindows: true,
      );

  test('正常系: bcdboot 方式で BCD を作り、仕上げ修復まで通る', () async {
    final runner = _WinRunner(winDir: winDir, espDir: espDir);
    final steps = <WinInstallStep>[];
    await wizard(runner).run(onStep: (s, m) => steps.add(s));

    expect(steps.first, WinInstallStep.precondition);
    expect(steps, contains(WinInstallStep.offlineFixes));
    expect(steps.last, WinInstallStep.done);
    final calls = runner.calls;
    int idx(String part) => calls.indexWhere((c) => c.contains(part));
    expect(idx('/Get-WimInfo'), lessThan(idx('/Apply-Image')));
    expect(idx('/Apply-Image'), lessThan(idx('bcdboot')));
    expect(idx('bcdboot'), lessThan(idx('/Add-Driver')));
    expect(idx('/Add-Driver'), lessThan(idx('reg load')));
    // createstore はもう使わない（spbcd が拒否するため）。
    expect(calls.any((c) => c.contains('/createstore')), isFalse);
    // 向け直しと WoA 向け設定が {default} に入る。
    final joined = calls.join('\n');
    expect(joined, contains('partition=R:'));
    expect(joined, contains('partition=S:'));
    expect(joined, contains('testsigning on'));
    expect(joined, contains('nointegritychecks on'));
    expect(joined, contains('recoveryenabled No'));
    expect(joined, contains('bootstatuspolicy IgnoreAllFailures'));
    expect(joined, contains(r'\Windows\System32\winload.efi'));
    // 仕上げ修復で状態が直っている。
    expect(runner.generalizationState, 7);
    expect(runner.qci2cStart, 4);
  });

  test('対象イメージの bcdboot 失敗時はホストテンプレートへフォールバックする', () async {
    final runner = _WinRunner(winDir: winDir, espDir: espDir)
      ..bcdbootFailsFirst = true;
    final steps = <WinInstallStep>[];
    await wizard(runner).run(onStep: (s, m) => steps.add(s));
    expect(runner.bcdbootAttempts, 2);
    expect(steps.last, WinInstallStep.done);
  });

  test('bcdboot が両方失敗したら退避した旧 BCD が復元される', () async {
    // 既存 ESP（旧 BCD あり）を用意する。
    String join(String base, String rel) =>
        '$base${Platform.pathSeparator}${rel.replaceAll('\\', Platform.pathSeparator)}';
    final msBoot = Directory(join(espDir, r'EFI\Microsoft\Boot'));
    await msBoot.create(recursive: true);
    final storeFile = File(join(espDir, r'EFI\Microsoft\Boot\BCD'));
    await storeFile.writeAsBytes([42]);

    final runner = _WinRunner(winDir: winDir, espDir: espDir)
      ..bcdbootAlwaysFails = true;
    await expectLater(
      wizard(runner).run(onStep: (s, m) {}),
      throwsStateError,
    );
    expect(runner.bcdbootAttempts, 2);
    // 正規パスに旧 BCD が戻っている（退避したままにしない）。
    expect(await storeFile.exists(), isTrue);
    expect(await storeFile.readAsBytes(), [42]);
    final leftovers =
        await msBoot.list().where((e) => e.path.contains('.bak-')).length;
    expect(leftovers, 0);
  });

  test('ARM64 でない WIM は展開前に止まる', () async {
    final runner = _WinRunner(
      winDir: winDir,
      espDir: espDir,
      wimInfo: 'Index : 1\nArchitecture : x64\n',
    );
    await expectLater(
      wizard(runner).run(onStep: (s, m) {}),
      throwsStateError,
    );
    expect(runner.calls.any((c) => c.contains('/Apply-Image')), isFalse);
  });

  test('Windows 以外のホストでは前提検証で止まる', () async {
    final runner = _WinRunner(winDir: winDir, espDir: espDir);
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
