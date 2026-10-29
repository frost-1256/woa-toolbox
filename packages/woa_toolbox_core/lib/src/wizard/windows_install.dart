import 'dart:io';

import '../device/command_runner.dart';
import '../troubleshoot/troubleshooter.dart';

enum WinInstallStep {
  precondition,
  verifyWim,
  applyImage,
  buildBcd,
  injectDrivers,
  offlineFixes,
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

  Future<CommandResult> _run(String exe, List<String> args, String what) async {
    final result = await runner.run(exe, args);
    if (!result.ok) {
      final tail =
          result.stderrText.isEmpty ? result.stdoutText : result.stderrText;
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
      throw StateError('Windows インストールウィザードは Windows 上でのみ動作します（DISM 依存）');
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
    if (driverPackDir != null && !await Directory(driverPackDir!).exists()) {
      throw StateError('ドライバーパックが見つかりません: $driverPackDir');
    }
    if (unattendPath != null && !await File(unattendPath!).exists()) {
      throw StateError('unattend.xml が見つかりません: $unattendPath');
    }

    // 2. WIM 検証（ARM64 であること）。
    onStep(WinInstallStep.verifyWim, 'install.wim を検証しています');
    // 注意: /Index を付けない概要出力には Architecture 行が含まれない
    // （実機 DISM で確認済み）。必ずインデックス詳細を取得すること。
    final info = await _run(
        'dism',
        ['/Get-WimInfo', '/WimFile:$wimPath', '/Index:$imageIndex'],
        'WIM 情報の取得');
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

    // 4. ブート構成（bcdboot 方式。DESIGN §12-2）。
    // bcdedit /createstore 製のストアは Sysprep の spbcd が
    // 「system store ではない」と拒否するため使わない。
    onStep(WinInstallStep.buildBcd, 'BCD を構築しています');
    final bootmgfw =
        File(_join(_winRoot, ['Windows', 'Boot', 'EFI', 'bootmgfw.efi']));
    if (!await bootmgfw.exists()) {
      throw StateError('展開したイメージに bootmgfw.efi がありません');
    }
    final espPart = _partitionOf(espPartition, espDir);
    final winPart = _partitionOf(winPartition, winDir);
    final msBootDir = Directory(_join(_espRoot, ['EFI', 'Microsoft', 'Boot']));
    final bootDir = Directory(_join(_espRoot, ['EFI', 'Boot']));
    final store = _join(msBootDir.path, ['BCD']);
    String? storeBackup;
    if (await File(store).exists()) {
      storeBackup = '$store.bak-${DateTime.now().millisecondsSinceEpoch}';
      await File(store).rename(storeBackup);
      onStep(WinInstallStep.buildBcd, '既存の BCD を $storeBackup に退避しました');
    }
    try {
      // まず対象イメージをソースに bcdboot。ホストの bcdboot が対象の
      // アーキテクチャを扱えない環境（ARM64 ソースで exit 193 等）では、
      // ホスト Windows をテンプレートにして生成し、後段で ARM64 の
      // bootmgfw に差し替えて向きを直す（実機で実証した手順）。
      var bcdboot = await runner.run('bcdboot', [
        _join(_winRoot, ['Windows']),
        '/s',
        _espRoot,
        '/f',
        'UEFI'
      ]);
      if (!bcdboot.ok) {
        onStep(WinInstallStep.buildBcd,
            '対象イメージからの bcdboot が失敗したため、ホスト Windows をテンプレートに再試行します');
        final hostWin = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        bcdboot = await runner
            .run('bcdboot', [hostWin, '/s', _espRoot, '/f', 'UEFI']);
        if (!bcdboot.ok) {
          // bcdboot の診断は stdout に出ることが多いため stderr 優先で拾う。
          final detail = bcdboot.stderrText.isEmpty
              ? bcdboot.stdoutText
              : bcdboot.stderrText;
          throw StateError('bcdboot が失敗しました: $detail');
        }
      }
      // ブートファイルは常に対象イメージ（ARM64）のものへ差し替える。
      await bootDir.create(recursive: true);
      await bootmgfw.copy(_join(msBootDir.path, ['bootmgfw.efi']));
      await bootmgfw.copy(_join(bootDir.path, ['bootaa64.efi']));
      Future<void> setEntry(String id, String name, String value) => _run(
            'bcdedit',
            ['/store', store, '/set', id, name, value],
            'BCD 設定 ($name)',
          );
      await setEntry('{bootmgr}', 'device', 'partition=$espPart');
      await setEntry('{default}', 'device', 'partition=$winPart');
      await setEntry('{default}', 'osdevice', 'partition=$winPart');
      await setEntry('{default}', 'path', r'\Windows\System32\winload.efi');
      await setEntry('{default}', 'systemroot', r'\Windows');
      await setEntry('{default}', 'detecthal', 'Yes');
      await setEntry('{default}', 'nx', 'OptIn');
      await setEntry('{default}', 'testsigning', 'on');
      await setEntry('{default}', 'nointegritychecks', 'on');
      await setEntry('{default}', 'recoveryenabled', 'No');
      await setEntry('{default}', 'bootstatuspolicy', 'IgnoreAllFailures');
    } catch (_) {
      // 構築のどこかで失敗したら、退避した旧 BCD を正規パスへ戻す。
      // 旧 BCD を退避したまま失敗すると ESP が起動不能になるため（H3）。
      if (storeBackup != null) {
        final partial = File(store);
        if (await partial.exists()) await partial.delete();
        await File(storeBackup).rename(store);
        onStep(WinInstallStep.buildBcd, 'BCD 構築に失敗したため、退避した旧 BCD を復元しました');
      }
      rethrow;
    }

    // 5. ドライバー注入（任意）。
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
    }

    // 6. 既知問題のオフライン修復（DESIGN §12 ライブラリの
    // インストール時サブセット。全量 DISM が qci2c の Start を戻す問題や
    // DISM 展開直後の GeneralizationState=6 をここで潰す。
    // OOBE 完了扱いは新規インストールには適用しない）。
    onStep(WinInstallStep.offlineFixes, '既知問題をチェックしています');
    final troubleshooter = Troubleshooter(
      runner: runner,
      winDir: winDir,
      espDir: espDir,
      hostIsWindows: hostIsWindows,
    );
    await troubleshooter.applyFixes(
      {
        IssueId.generalizationState,
        IssueId.qcTreeStart,
        IssueId.qci2cStart,
      },
      onProgress: (m) => onStep(WinInstallStep.offlineFixes, m),
    );

    // 7. unattend.xml 配置（任意）。
    if (unattendPath == null) {
      onStep(WinInstallStep.placeUnattend, 'unattend 配置はスキップしました');
    } else {
      onStep(WinInstallStep.placeUnattend, 'unattend.xml を配置しています');
      final panther = Directory(_join(_winRoot, ['Windows', 'Panther']));
      await panther.create(recursive: true);
      await File(unattendPath!).copy(_join(panther.path, ['unattend.xml']));
    }

    // 8. 検証。
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

    // 9. 完了。
    onStep(WinInstallStep.done, '完了しました。UEFI で起動して初回セットアップを確認してください');
  }
}
