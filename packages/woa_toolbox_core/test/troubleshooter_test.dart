import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// reg.exe / bcdedit をエミュレートするフェイク。値はメモリ上の
/// マップに保持し、reg add で書き換わる（読み戻し検証が通る）。
///
/// 重要: 出力のキーパスは実 reg.exe と同じ正規化形式
/// （`HKEY_LOCAL_MACHINE\...`）で返す。入力は `HKLM` 短縮形でも
/// 出力は必ず長い形式になるのが実機の挙動で、ここを短縮形のまま
/// エコーすると subkeys() の接頭辞バグ（C1）を検出できない。
class _RegRunner implements CommandRunner {
  _RegRunner({required this.values, required this.subkeyMap});

  /// 'HKLM\WOA_OFF\...' -> { 値名: [型, データ文字列] }
  final Map<String, Map<String, List<String>>> values;

  /// キー -> 直下サブキー名
  final Map<String, List<String>> subkeyMap;

  final List<String> calls = [];
  bool bcdRecoveryOff = false;
  bool bcdIgnoreFailures = false;

  /// 実機の bcdedit 出力に合わせた {default} の device 表記。
  String bcdDevice = 'partition=R:';

  /// 実 reg.exe の出力形式（ルートを正規化）に変換する。
  static String _display(String keyName) =>
      keyName.replaceFirst(r'HKLM\', r'HKEY_LOCAL_MACHINE\');

  CommandResult _ok([String out = 'The operation completed successfully.']) =>
      CommandResult(
          exitCode: 0,
          stdoutBytes: Uint8List.fromList(utf8.encode(out)),
          stderrText: '');

  CommandResult _fail() => CommandResult(
      exitCode: 1,
      stdoutBytes: Uint8List.fromList(utf8.encode(
          'ERROR: The system was unable to find the specified registry key or value.')),
      stderrText:
          'ERROR: The system was unable to find the specified registry key or value.');

  @override
  Future<CommandResult> run(String executable, List<String> args) async {
    calls.add('$executable ${args.join(' ')}');
    if (executable == 'reg') return _reg(args);
    if (executable == 'bcdedit') return _bcdedit(args);
    return _ok();
  }

  CommandResult _reg(List<String> a) {
    final op = a[0];
    if (op == 'load' || op == 'unload') return _ok();
    final keyName = a[1];
    if (op == 'query' && a.contains('/v')) {
      final name = a[a.indexOf('/v') + 1];
      final v = values[keyName]?[name];
      if (v == null) return _fail();
      final data =
          v[0] == 'REG_DWORD' ? '0x${int.parse(v[1]).toRadixString(16)}' : v[1];
      return _ok('\n${_display(keyName)}\n    $name    ${v[0]}    $data\n');
    }
    if (op == 'query') {
      final subs = subkeyMap[keyName];
      if (subs == null && !values.containsKey(keyName)) return _fail();
      final lines = StringBuffer('\n${_display(keyName)}\n');
      for (final s in subs ?? const <String>[]) {
        lines.writeln('${_display(keyName)}\\$s');
      }
      return _ok(lines.toString());
    }
    if (op == 'add') {
      final name = a[a.indexOf('/v') + 1];
      final type = a[a.indexOf('/t') + 1];
      final data = a[a.indexOf('/d') + 1];
      values.putIfAbsent(keyName, () => {})[name] = [type, data];
      return _ok();
    }
    return _ok();
  }

  CommandResult _bcdedit(List<String> a) {
    if (a.contains('/enum')) {
      return _ok('''
Windows Boot Loader
-------------------
identifier              {default}
device                  $bcdDevice
path                    \\Windows\\System32\\winload.efi
osdevice                $bcdDevice
recoveryenabled         ${bcdRecoveryOff ? 'No' : 'Yes'}
${bcdIgnoreFailures ? 'bootstatuspolicy        IgnoreAllFailures' : ''}
''');
    }
    if (a.contains('/set')) {
      final name = a[a.length - 2];
      final value = a[a.length - 1];
      if (name == 'recoveryenabled' && value == 'No') bcdRecoveryOff = true;
      if (name == 'bootstatuspolicy' && value == 'IgnoreAllFailures') {
        bcdIgnoreFailures = true;
      }
      return _ok();
    }
    return _ok();
  }
}

void main() {
  late Directory tmp;
  late String winDir;
  late String espDir;

  String join(String base, String rel) =>
      '$base${Platform.pathSeparator}${rel.replaceAll('\\', Platform.pathSeparator)}';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('woa_troubleshoot');
    winDir = join(tmp.path, 'win');
    espDir = join(tmp.path, 'esp');
    final config = Directory(join(winDir, r'Windows\System32\config'));
    await config.create(recursive: true);
    await File(join(winDir, r'Windows\System32\config\SYSTEM'))
        .writeAsBytes([1, 2, 3]);
    final bcdDir = Directory(join(espDir, r'EFI\Microsoft\Boot'));
    await bcdDir.create(recursive: true);
    await File(join(espDir, r'EFI\Microsoft\Boot\BCD')).writeAsBytes([7]);
  });

  tearDown(() => tmp.delete(recursive: true));

  const mount = r'HKLM\WOA_OFF';

  _RegRunner brokenRunner() => _RegRunner(
        values: {
          '$mount\\Setup\\Status\\SysprepStatus': {
            'GeneralizationState': ['REG_DWORD', '6'],
            'CleanupState': ['REG_DWORD', '1'],
          },
          '$mount\\Setup': {
            'SystemSetupInProgress': ['REG_DWORD', '1'],
            'SetupType': ['REG_DWORD', '2'],
            'CmdLine': ['REG_SZ', r'oobe\setup.exe'],
          },
          '$mount\\Setup\\Status\\ChildCompletion': {
            'setup.exe': ['REG_DWORD', '1'],
          },
          '$mount\\ControlSet001\\Services\\QcTrEE': {
            'Start': ['REG_DWORD', '0'],
          },
          '$mount\\ControlSet001\\Services\\qci2c': {
            'Start': ['REG_DWORD', '3'],
          },
          '$mount\\ControlSet001\\Enum\\ACPI\\QCOM0A1E\\2&daba3ff&0': {
            'ConfigFlags': ['REG_DWORD', '0'],
          },
          '$mount\\ControlSet001\\Enum\\ACPI\\QCOM0A1B\\2&daba3ff&0': {
            'ConfigFlags': ['REG_DWORD', '0'],
          },
        },
        subkeyMap: {
          '$mount\\ControlSet001\\Enum\\ACPI\\QCOM0A1E': ['2&daba3ff&0'],
          '$mount\\ControlSet001\\Enum\\ACPI\\QCOM0A1B': ['2&daba3ff&0'],
          '$mount\\ControlSet001\\Enum\\ACPI\\QCOM0A1C': <String>[],
          '$mount\\ControlSet001\\Enum\\ACPI\\QCOM0AB0': <String>[],
        },
      );

  Troubleshooter shooter(CommandRunner r) => Troubleshooter(
        runner: r,
        winDir: winDir,
        espDir: espDir,
        // フェイクの BCD は R: を指す。{default} の向き検証を通すため。
        winPartition: 'R:',
        hostIsWindows: true,
      );

  Finding byId(TroubleshootReport rep, String id) =>
      rep.findings.firstWhere((f) => f.id == id);

  test('壊れたイメージ: 全項目が検出される', () async {
    final rep = await shooter(brokenRunner()).diagnose();
    expect(
        byId(rep, IssueId.generalizationState).status, FindingStatus.detected);
    expect(byId(rep, IssueId.oobeIncomplete).status, FindingStatus.detected);
    expect(byId(rep, IssueId.qcTreeStart).status, FindingStatus.detected);
    expect(byId(rep, IssueId.qci2cStart).status, FindingStatus.detected);
    expect(
        byId(rep, IssueId.subsystemConfigFlags).status, FindingStatus.detected);
    expect(byId(rep, IssueId.bcdSettings).status, FindingStatus.detected);
    expect(rep.notes.any((n) => n.contains('ft3680.log なし')), isTrue);
  });

  test('修復: 全項目が ok になり、ハイブのバックアップが作られる', () async {
    final runner = brokenRunner();
    final progress = <String>[];
    final rep = await shooter(runner).applyFixes(
      {
        IssueId.generalizationState,
        IssueId.oobeIncomplete,
        IssueId.qcTreeStart,
        IssueId.qci2cStart,
        IssueId.subsystemConfigFlags,
        IssueId.bcdSettings,
      },
      onProgress: progress.add,
    );
    for (final id in [
      IssueId.generalizationState,
      IssueId.oobeIncomplete,
      IssueId.qcTreeStart,
      IssueId.qci2cStart,
      IssueId.subsystemConfigFlags,
      IssueId.bcdSettings,
    ]) {
      expect(byId(rep, id).status, FindingStatus.ok, reason: id);
    }
    expect(progress.any((m) => m.contains('バックアップ')), isTrue);
    final backups = await Directory(join(winDir, r'Windows\System32\config'))
        .list()
        .where((e) => e.path.contains('.bak-'))
        .length;
    expect(backups, 1);
    // BCD も編集前にバックアップされる（H2）。
    final bcdBackups = await Directory(join(espDir, r'EFI\Microsoft\Boot'))
        .list()
        .where((e) => e.path.contains('.bak-'))
        .length;
    expect(bcdBackups, 1);
    // QSM だけ 1、ADSP は 0 のまま（finalize の意味どおり）。
    expect(
        runner.values[
                '$mount\\ControlSet001\\Enum\\ACPI\\QCOM0A1E\\2&daba3ff&0']![
            'ConfigFlags']![1],
        '1');
  });

  test('修復は検出項目だけ: 存在しないサービスへ幽霊キーを作らない', () async {
    final runner = _RegRunner(
      values: {
        '$mount\\Setup\\Status\\SysprepStatus': {
          'GeneralizationState': ['REG_DWORD', '7'],
        },
        '$mount\\Setup': {
          'SystemSetupInProgress': ['REG_DWORD', '0'],
        },
        '$mount\\Setup\\Status\\ChildCompletion': {
          'setup.exe': ['REG_DWORD', '3'],
        },
      },
      subkeyMap: const {},
    );
    await shooter(runner).applyFixes(
      {IssueId.qcTreeStart, IssueId.qci2cStart},
      onProgress: (_) {},
    );
    expect(runner.values.containsKey('$mount\\ControlSet001\\Services\\QcTrEE'),
        isFalse);
    expect(runner.values.containsKey('$mount\\ControlSet001\\Services\\qci2c'),
        isFalse);
    expect(runner.calls.any((c) => c.startsWith('reg add')), isFalse);
  });

  test('健全なイメージ: ok と対象外が並ぶ', () async {
    final runner = _RegRunner(
      values: {
        '$mount\\Setup\\Status\\SysprepStatus': {
          'GeneralizationState': ['REG_DWORD', '7'],
        },
        '$mount\\Setup': {
          'SystemSetupInProgress': ['REG_DWORD', '0'],
        },
        '$mount\\Setup\\Status\\ChildCompletion': {
          'setup.exe': ['REG_DWORD', '3'],
        },
        '$mount\\ControlSet001\\Services\\qci2c': {
          'Start': ['REG_DWORD', '4'],
        },
      },
      subkeyMap: const {},
    );
    runner.bcdRecoveryOff = true;
    runner.bcdIgnoreFailures = true;
    final rep = await shooter(runner).diagnose();
    expect(byId(rep, IssueId.generalizationState).status, FindingStatus.ok);
    expect(byId(rep, IssueId.oobeIncomplete).status, FindingStatus.ok);
    expect(byId(rep, IssueId.qcTreeStart).status, FindingStatus.notApplicable);
    expect(byId(rep, IssueId.qci2cStart).status, FindingStatus.ok);
    expect(byId(rep, IssueId.subsystemConfigFlags).status,
        FindingStatus.notApplicable);
    expect(byId(rep, IssueId.bcdSettings).status, FindingStatus.ok);
  });

  test('OOBE: DESIGN 条件を満たさない組み合わせは detected にしない', () async {
    // SystemSetupInProgress=0 で setup.exe!=3: 文書化されたループではない。
    final notLooping = _RegRunner(
      values: {
        '$mount\\Setup': {
          'SystemSetupInProgress': ['REG_DWORD', '0'],
        },
        '$mount\\Setup\\Status\\ChildCompletion': {
          'setup.exe': ['REG_DWORD', '1'],
        },
      },
      subkeyMap: const {},
    );
    var rep = await shooter(notLooping).diagnose();
    expect(byId(rep, IssueId.oobeIncomplete).status, FindingStatus.unknown);
    expect(byId(rep, IssueId.oobeIncomplete).fixable, isFalse);

    // 進行中=1 だが ChildCompletion が読めない（部分読み）: unknown。
    final partial = _RegRunner(
      values: {
        '$mount\\Setup': {
          'SystemSetupInProgress': ['REG_DWORD', '1'],
        },
      },
      subkeyMap: const {},
    );
    rep = await shooter(partial).diagnose();
    expect(byId(rep, IssueId.oobeIncomplete).status, FindingStatus.unknown);
    expect(byId(rep, IssueId.oobeIncomplete).fixable, isFalse);
  });

  test('BCD: {default} が別のボリュームを指す場合は修復しない', () async {
    final runner = brokenRunner()..bcdDevice = 'partition=Z:';
    final rep = await shooter(runner).diagnose();
    expect(byId(rep, IssueId.bcdSettings).status, FindingStatus.unknown);
    expect(byId(rep, IssueId.bcdSettings).fixable, isFalse);

    await shooter(runner).applyFixes(
      {IssueId.bcdSettings},
      onProgress: (_) {},
    );
    // 向きが違うストアへは書き込まないし、バックアップも作らない。
    expect(
        runner.calls.any((c) => c.startsWith('bcdedit') && c.contains('/set')),
        isFalse);
    final bcdBackups = await Directory(join(espDir, r'EFI\Microsoft\Boot'))
        .list()
        .where((e) => e.path.contains('.bak-'))
        .length;
    expect(bcdBackups, 0);
  });
}
