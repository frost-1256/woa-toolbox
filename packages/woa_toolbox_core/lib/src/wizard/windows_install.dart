import 'dart:io';

import '../device/command_runner.dart';

enum WinInstallStep {
  precondition,
  verifyWim,
  applyImage,
  buildBcd,
  injectDrivers,
  placeUnattend,
  verify,
  done,
}

/// Windows インストールウィザードの状態機械（DESIGN.md §11）。
///
/// 手作業で実証した導入手順を「前提検証 → 実行 → 成功確認」の
/// ステップ列にしたもの。PC 側の操作のみで、対象ボリュームは
/// Recovery の Mass Storage で見えている esp / win を明示的に渡す
/// （自動同定はしない＝誤爆防止）。管理者権限でアプリを実行する前提。
class WindowsInstallWizard {
  WindowsInstallWizard({
    required this.runner,
    required this.winDir,
    required this.espDir,
    required this.wimPath,
    this.imageIndex = 1,
    this.driverPackDir,
    this.unattendPath,
    this.winPartition,
    this.espPartition,
    bool? hostIsWindows,
  }) : hostIsWindows = hostIsWindows ?? Platform.isWindows;

  final CommandRunner runner;

  /// win ボリュームのルート（例: `R:\`）。
  final String winDir;

  /// esp ボリュームのルート（例: `S:\`）。
  final String espDir;

  final String wimPath;
  final int imageIndex;
  final String? driverPackDir;
  final String? unattendPath;

  /// BCD の partition= に使う表記（例: `R:`）。null なら winDir から推定。
  final String? winPartition;
  final String? espPartition;
  final bool hostIsWindows;

  // ファイルシステムパスはホストの区切り文字で組み立てる
  // （BCD の値そのものは Windows 形式のまま）。
  static String _join(String base, List<String> parts) {
    var b = base;
    if (!b.endsWith(Platform.pathSeparator)) b += Platform.pathSeparator;
    return b + parts.join(Platform.pathSeparator);
  }

  String get _winRoot {
    var w = winDir;
    if (!w.endsWith(Platform.pathSeparator)) w += Platform.pathSeparator;
    return w;
  }

  String get _espRoot {
    var e = espDir;
    if (!e.endsWith(Platform.pathSeparator)) e += Platform.pathSeparator;
    return e;
  }

  String _partitionOf(String? explicit, String dir) {
    if (explicit != null) return explicit;
    final m = RegExp(r'^([A-Za-z]:)').firstMatch(dir);
    return m != null ? m.group(1)!.toUpperCase() : dir;
  }

  Future<CommandResult> _run(
      String exe, List<String> args, String what) async {
    final result = await runner.run(exe, args);
    if (!result.ok) {
      final tail = result.stderrText.isEmpty
          ? result.stdoutText
          : result.stderrText;
      throw StateError('$what が失敗しました: $tail');
    }
    return result;
  }

  Future<void> run({
    required void Function(WinInstallStep step, String message) onStep,
  }) async {
    // 1. 前提検証。
    onStep(WinInstallStep.precondition, '前提を検証しています');
    if (!hostIsWindows) {
      throw StateError(
          'Windows インストールウィザードは Windows 上でのみ動作します（DISM 依存）');
    }
    if (!await Directory(winDir).exists()) {
      throw StateError('win ボリュームが見つかりません: $winDir');
    }
    if (!await Directory(espDir).exists()) {
      throw StateError('esp ボリュームが見つかりません: $espDir');
    }
    if (await Directory(_join(_winRoot, ['Windows'])).exists()) {
      throw StateError('win ボリュームに既存の Windows があります（上書きは未対応です）');
    }
    if (!await File(wimPath).exists()) {
      throw StateError('install.wim が見つかりません: $wimPath');
    }
    if (driverPackDir != null &&
        !await Directory(driverPackDir!).exists()) {
      throw StateError('ドライバーパックが見つかりません: $driverPackDir');
    }
    if (unattendPath != null && !await File(unattendPath!).exists()) {
      throw StateError('unattend.xml が見つかりません: $unattendPath');
    }

    // 2. WIM 検証（ARM64 であること）。
    onStep(WinInstallStep.verifyWim, 'install.wim を検証しています');
    final info = await _run(
        'dism', ['/Get-WimInfo', '/WimFile:$wimPath'], 'WIM 情報の取得');
    if (!info.stdoutText.toUpperCase().contains('ARM64')) {
      throw StateError('この WIM に ARM64 イメージが見つかりません');
    }
    if (!RegExp('Index\\s*:\\s*$imageIndex\\b|インデックス\\s*:\\s*$imageIndex\\b')
        .hasMatch(info.stdoutText)) {
      onStep(WinInstallStep.verifyWim,
          '警告: インデックス $imageIndex が WIM 情報で確認できませんでした（続行します）');
    }

    // 3. イメージ展開。
    onStep(WinInstallStep.applyImage,
        'イメージを展開しています（インデックス $imageIndex → $winDir）');
    await _run(
      'dism',
      [
        '/Apply-Image',
        '/ImageFile:$wimPath',
        '/Index:$imageIndex',
        '/ApplyDir:$_winRoot',
      ],
      'イメージの展開',
    );

    // 4. ブート構成（BCD 新規構築＋手作業版 make_bcd.bat と同じ設定）。
    onStep(WinInstallStep.buildBcd, 'BCD を構築しています');
    final bootmgfw =
        File(_join(_winRoot, ['Windows', 'Boot', 'EFI', 'bootmgfw.efi']));
    if (!await bootmgfw.exists()) {
      throw StateError('展開したイメージに bootmgfw.efi がありません');
    }
    final msBootDir =
        Directory(_join(_espRoot, ['EFI', 'Microsoft', 'Boot']));
    await msBootDir.create(recursive: true);
    final bootDir = Directory(_join(_espRoot, ['EFI', 'Boot']));
    await bootDir.create(recursive: true);
    await bootmgfw.copy(_join(msBootDir.path, ['bootmgfw.efi']));
    await bootmgfw.copy(_join(bootDir.path, ['bootaa64.efi']));

    final store = _join(msBootDir.path, ['BCD']);
    if (await File(store).exists()) {
      final backup = '$store.bak-${DateTime.now().millisecondsSinceEpoch}';
      await File(store).rename(backup);
      onStep(WinInstallStep.buildBcd, '既存の BCD を $backup に退避しました');
    }
    await _run('bcdedit', ['/createstore', store], 'BCD ストアの作成');
    final espPart = _partitionOf(espPartition, espDir);
    final winPart = _partitionOf(winPartition, winDir);
    await _run(
        'bcdedit',
        ['/store', store, '/create', '{bootmgr}', '/d', 'Windows Boot Manager'],
        'bootmgr の作成');
    await _run(
        'bcdedit',
        ['/store', store, '/set', '{bootmgr}', 'device', 'partition=$espPart'],
        'bootmgr の設定');
    final created = await _run(
        'bcdedit',
        ['/store', store, '/create', '/d', 'Windows 11', '/application', 'osloader'],
        'OS ローダーの作成');
    final guid = RegExp(r'\{[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}')
        .firstMatch(created.stdoutText)
        ?.group(0);
    if (guid == null) {
      throw StateError('OS ローダーの GUID を取得できませんでした: ${created.stdoutText}');
    }
    Future<void> setLoader(String name, String value) => _run(
          'bcdedit',
          ['/store', store, '/set', guid, name, value],
          'ローダー設定 ($name)',
        );
    await setLoader('device', 'partition=$winPart');
    await setLoader('osdevice', 'partition=$winPart');
    await setLoader('path', r'\Windows\System32\winload.efi');
    await setLoader('systemroot', r'\Windows');
    await setLoader('detecthal', 'Yes');
    await setLoader('nx', 'OptIn');
    await setLoader('testsigning', 'on');
    await setLoader('nointegritychecks', 'on');
    await setLoader('recoveryenabled', 'No');
    await _run('bcdedit', ['/store', store, '/default', guid], '既定エントリの設定');
    await _run(
        'bcdedit',
        ['/store', store, '/set', '{bootmgr}', 'displayorder', guid],
        '表示順の設定');
    await _run(
        'bcdedit',
        ['/store', store, '/set', '{bootmgr}', 'default', guid],
        'bootmgr 既定の設定');

    // 5. ドライバー注入（任意）＋ qci2c の Start=4 再適用。
    if (driverPackDir == null) {
      onStep(WinInstallStep.injectDrivers, 'ドライバー注入はスキップしました');
    } else {
      onStep(WinInstallStep.injectDrivers, 'ドライバーを注入しています');
      await _run(
        'dism',
        [
          '/Image:$_winRoot',
          '/Add-Driver',
          '/Driver:$driverPackDir',
          '/Recurse',
        ],
        'ドライバーの注入',
      );
      // 全量 DISM は qci2c の Start を 3 に戻すため、オフラインで 4 に直す。
      const hiveKey = r'HKLM\WOA_OFF';
      await _run(
          'reg',
          [
            'load',
            hiveKey,
            _join(_winRoot, ['Windows', 'System32', 'config', 'SYSTEM']),
          ],
          'SYSTEM ハイブのロード');
      try {
        final query = await runner.run('reg',
            ['query', '$hiveKey\\ControlSet001\\Services\\qci2c', '/v', 'Start']);
        if (query.ok) {
          await _run(
              'reg',
              [
                'add',
                '$hiveKey\\ControlSet001\\Services\\qci2c',
                '/v',
                'Start',
                '/t',
                'REG_DWORD',
                '/d',
                '4',
                '/f',
              ],
              'qci2c の Start 修正');
          onStep(WinInstallStep.injectDrivers,
              'qci2c の Start を 4 に戻しました（WHEA 対策）');
        } else {
          onStep(WinInstallStep.injectDrivers,
              '警告: qci2c サービスが見つかりませんでした（未注入の可能性）');
        }
      } finally {
        await runner.run('reg', ['unload', hiveKey]);
      }
    }

    // 6. unattend.xml 配置（任意）。
    if (unattendPath == null) {
      onStep(WinInstallStep.placeUnattend, 'unattend 配置はスキップしました');
    } else {
      onStep(WinInstallStep.placeUnattend, 'unattend.xml を配置しています');
      final panther = Directory(_join(_winRoot, ['Windows', 'Panther']));
      await panther.create(recursive: true);
      await File(unattendPath!).copy(_join(panther.path, ['unattend.xml']));
    }

    // 7. 検証。
    onStep(WinInstallStep.verify, '成果物を検証しています');
    final missing = <String>[];
    if (!await File(_join(_winRoot, ['Windows', 'System32', 'winload.efi']))
        .exists()) {
      missing.add('winload.efi');
    }
    if (!await File(store).exists()) missing.add('BCD');
    if (!await File(_join(bootDir.path, ['bootaa64.efi'])).exists()) {
      missing.add('bootaa64.efi');
    }
    if (missing.isNotEmpty) {
      throw StateError('検証に失敗しました: ${missing.join(', ')} がありません');
    }

    // 8. 完了。
    onStep(WinInstallStep.done,
        '完了しました。UEFI で起動して初回セットアップを確認してください');
  }
}
