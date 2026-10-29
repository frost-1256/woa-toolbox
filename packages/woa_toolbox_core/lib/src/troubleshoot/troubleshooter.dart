import 'dart:io';
import 'dart:typed_data';

import '../device/command_runner.dart';
import 'offline_hive.dart';

enum FindingStatus { detected, ok, notApplicable, unknown }

class Finding {
  const Finding({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
    required this.fixable,
  });

  final String id;
  final String title;
  final FindingStatus status;
  final String detail;

  /// 検出時にオフライン修復が可能か。
  final bool fixable;
}

class TroubleshootReport {
  const TroubleshootReport({required this.findings, required this.notes});

  final List<Finding> findings;

  /// ログ類から得た診断メモ（修復対象ではない情報）。
  final List<String> notes;
}

/// 既知問題の ID（DESIGN.md §12 のライブラリ）。
abstract final class IssueId {
  static const generalizationState = 'generalization_state_6';
  static const oobeIncomplete = 'oobe_incomplete';
  static const qcTreeStart = 'qctree_start';
  static const qci2cStart = 'qci2c_start';
  static const subsystemConfigFlags = 'subsystem_configflags';
  static const bcdSettings = 'bcd_settings';
}

/// Gadget で見えている Windows インストールをオフライン診断し、
/// 既知問題を修復する（DESIGN.md §12）。Windows ホスト専用（reg.exe 依存）。
class Troubleshooter {
  Troubleshooter({
    required this.runner,
    required this.winDir,
    required this.espDir,
    this.winPartition,
    bool? hostIsWindows,
  }) : hostIsWindows = hostIsWindows ?? Platform.isWindows;

  final CommandRunner runner;

  /// win ボリュームのルート（例: `R:\`）。
  final String winDir;

  /// esp ボリュームのルート（例: `E:\`）。
  final String espDir;

  /// BCD の device 照合に使う win ボリューム表記（例: `R:`）。
  /// null なら [winDir] からドライブレターを推定する（推定できない
  /// 環境では device 照合を省略し、path のみで検証する）。
  final String? winPartition;

  final bool hostIsWindows;

  /// {default} が指すべき win ボリュームのドライブレター（例: `R:`）。
  String? get _winLetter {
    final src = winPartition ?? winDir;
    final m = RegExp(r'^([A-Za-z]:)').firstMatch(src);
    return m?.group(1)?.toUpperCase();
  }

  static String _join(String base, List<String> parts) {
    var b = base;
    if (!b.endsWith(Platform.pathSeparator)) b += Platform.pathSeparator;
    return b + parts.join(Platform.pathSeparator);
  }

  String get _hiveFile =>
      _join(winDir, ['Windows', 'System32', 'config', 'SYSTEM']);

  String get _bcdFile => _join(espDir, ['EFI', 'Microsoft', 'Boot', 'BCD']);

  OfflineHive _hive() => OfflineHive(runner: runner, hiveFile: _hiveFile);

  void _precondition() {
    if (!hostIsWindows) {
      throw StateError('トラブルシューティングは Windows 上でのみ動作します（reg.exe 依存）');
    }
    if (!File(_hiveFile).existsSync()) {
      throw StateError('SYSTEM ハイブが見つかりません: $_hiveFile');
    }
  }

  // ---- 診断（読み取り専用） ----

  Future<List<Finding>> _diagnoseWithHive(OfflineHive hive) async {
    return <Finding>[
      await _checkGeneralization(hive),
      await _checkOobe(hive),
      await _checkServiceStart(hive, IssueId.qcTreeStart, 'QcTrEE',
          'QcTrEE の Start（0=ブート開始は spacewar では早期ブートで落ちる）'),
      await _checkServiceStart(hive, IssueId.qci2cStart, 'qci2c',
          'qci2c の Start（4 以外は WHEA 0x124 のリスク）'),
      await _checkSubsystemConfigFlags(hive),
    ];
  }

  Future<TroubleshootReport> diagnose() async {
    _precondition();
    final hive = _hive();
    final findings = await hive.session(() => _diagnoseWithHive(hive));
    findings.add(await _checkBcd());
    return TroubleshootReport(findings: findings, notes: await _logNotes());
  }

  Future<Finding> _checkGeneralization(OfflineHive hive) async {
    const title = 'Sysprep 一般化状態（GeneralizationState）';
    final v = await hive.queryDword(
        r'Setup\Status\SysprepStatus', 'GeneralizationState');
    if (v == null) {
      return const Finding(
        id: IssueId.generalizationState,
        title: title,
        status: FindingStatus.unknown,
        detail: r'SysprepStatus\GeneralizationState が読めませんでした',
        fixable: false,
      );
    }
    if (v == 6) {
      return Finding(
        id: IssueId.generalizationState,
        title: title,
        status: FindingStatus.detected,
        detail: 'GeneralizationState=6 のため windeploy が invalid state で失敗します',
        fixable: true,
      );
    }
    return Finding(
      id: IssueId.generalizationState,
      title: title,
      status: v == 7 ? FindingStatus.ok : FindingStatus.unknown,
      detail: 'GeneralizationState=$v',
      fixable: false,
    );
  }

  Future<Finding> _checkOobe(OfflineHive hive) async {
    const title = 'OOBE 完了状態（ChildCompletion）';
    final inProgress = await hive.queryDword('Setup', 'SystemSetupInProgress');
    final child =
        await hive.queryDword(r'Setup\Status\ChildCompletion', 'setup.exe');
    // DESIGN §12-3 の条件どおりに検出する:
    // SystemSetupInProgress=1 かつ ChildCompletion\setup.exe≠3 のときだけ
    // 「予期せず再起動しました」ループとみなす。どちらかの値が読めない
    // （null）場合は部分読みとして detected にせず unknown にする
    // （未ブートの新品イメージや一時的な読み取り失敗を誤検出しない）。
    if (inProgress == 1 && child != null && child != 3) {
      return Finding(
        id: IssueId.oobeIncomplete,
        title: title,
        status: FindingStatus.detected,
        detail:
            'SystemSetupInProgress=$inProgress / ChildCompletion setup.exe=$child のため「予期せず再起動しました」ダイアログで止まります。修復すると OOBE 完了扱いになりますが、ローカルアカウントが未作成の場合があります',
        fixable: true,
      );
    }
    if (child == 3 && inProgress == 0) {
      return const Finding(
        id: IssueId.oobeIncomplete,
        title: title,
        status: FindingStatus.ok,
        detail: 'OOBE は完了しています',
        fixable: false,
      );
    }
    return Finding(
      id: IssueId.oobeIncomplete,
      title: title,
      status: FindingStatus.unknown,
      detail:
          'SystemSetupInProgress=$inProgress / ChildCompletion setup.exe=$child: DESIGN §12-3 の検出条件（進行中=1 かつ setup.exe≠3）を満たさないため判定できません',
      fixable: false,
    );
  }

  Future<Finding> _checkServiceStart(
      OfflineHive hive, String id, String service, String title) async {
    final v =
        await hive.queryDword('ControlSet001\\Services\\$service', 'Start');
    if (v == null) {
      return Finding(
        id: id,
        title: title,
        status: FindingStatus.notApplicable,
        detail: 'サービス $service が存在しません（未注入）',
        fixable: false,
      );
    }
    if (v == 4) {
      return Finding(
        id: id,
        title: title,
        status: FindingStatus.ok,
        detail: '$service の Start=4（無効）です',
        fixable: false,
      );
    }
    return Finding(
      id: id,
      title: title,
      status: FindingStatus.detected,
      detail: '$service の Start=$v です',
      fixable: true,
    );
  }

  /// finalize_config 相当: QSM=QCOM0A1E は ConfigFlags=1（無効化）が正。
  static const _subsys = <String, int>{
    'QCOM0A1E': 1, // QSM
    'QCOM0A1B': 0, // ADSP
    'QCOM0A1C': 0, // AMSS
    'QCOM0AB0': 0, // NSP0
  };

  Future<List<String>> _instances(OfflineHive hive, String devId) =>
      hive.subkeys('ControlSet001\\Enum\\ACPI\\$devId');

  Future<Finding> _checkSubsystemConfigFlags(OfflineHive hive) async {
    const title = 'サブシステム ConfigFlags（QSM のタッチ電源毒）';
    final qsmInstances = await _instances(hive, 'QCOM0A1E');
    if (qsmInstances.isEmpty) {
      return const Finding(
        id: IssueId.subsystemConfigFlags,
        title: title,
        status: FindingStatus.notApplicable,
        detail: 'Enum に QSM (QCOM0A1E) がありません（未ブートのイメージでは対象外）',
        fixable: false,
      );
    }
    final flags = await hive.queryDword(
        'ControlSet001\\Enum\\ACPI\\QCOM0A1E\\${qsmInstances.first}',
        'ConfigFlags');
    if (flags == 1) {
      return const Finding(
        id: IssueId.subsystemConfigFlags,
        title: title,
        status: FindingStatus.ok,
        detail: 'QSM の ConfigFlags=1（無効化済み）です',
        fixable: false,
      );
    }
    return Finding(
      id: IssueId.subsystemConfigFlags,
      title: title,
      status: FindingStatus.detected,
      detail:
          'QSM の ConfigFlags=$flags です。QSM が有効だとサブシステム起動時の電源再計算でタッチのレールが落ちます',
      fixable: true,
    );
  }

  Future<Finding> _checkBcd() async {
    const title = 'BCD 設定（recoveryenabled / bootstatuspolicy）';
    if (!await File(_bcdFile).exists()) {
      return const Finding(
        id: IssueId.bcdSettings,
        title: title,
        status: FindingStatus.notApplicable,
        detail: 'ESP に BCD がありません',
        fixable: false,
      );
    }
    final r =
        await runner.run('bcdedit', ['/store', _bcdFile, '/enum', '{default}']);
    if (!r.ok) {
      return const Finding(
        id: IssueId.bcdSettings,
        title: title,
        status: FindingStatus.unknown,
        detail: 'BCD を列挙できませんでした',
        fixable: false,
      );
    }
    final out = r.stdoutText;
    // {default} が選択中の win ボリュームの Windows ローダーであることを
    // 先に検証する。複数エントリのストアや既定が別のローダーを指す
    // ストアでは、無関係なオブジェクトを書き換えないよう detected に
    // せず unknown とする（H2）。
    final pathMatch =
        RegExp(r'^\s*path\s+(\S+)', multiLine: true).firstMatch(out);
    final deviceMatch =
        RegExp(r'^\s*device\s+partition=([A-Za-z]:)', multiLine: true)
            .firstMatch(out);
    final loaderPath = pathMatch?.group(1);
    final deviceLetter = deviceMatch?.group(1)?.toUpperCase();
    final expectedLetter = _winLetter;
    final pathOk = loaderPath != null &&
        loaderPath.toLowerCase() == r'\windows\system32\winload.efi';
    final deviceOk = expectedLetter == null ||
        (deviceLetter != null && deviceLetter == expectedLetter);
    if (!pathOk || !deviceOk) {
      return Finding(
        id: IssueId.bcdSettings,
        title: title,
        status: FindingStatus.unknown,
        detail:
            '既定のブートエントリが対象の Windows を指していません（path=$loaderPath / device=${deviceLetter ?? '不明'} / 期待 device=$expectedLetter）。安全のため BCD 修復は行いません',
        fixable: false,
      );
    }
    final recoveryOff =
        RegExp(r'recoveryenabled\s+No', caseSensitive: false).hasMatch(out);
    final ignoreFailures =
        RegExp(r'bootstatuspolicy\s+IgnoreAllFailures', caseSensitive: false)
            .hasMatch(out);
    if (recoveryOff && ignoreFailures) {
      return const Finding(
        id: IssueId.bcdSettings,
        title: title,
        status: FindingStatus.ok,
        detail: 'recoveryenabled=No / bootstatuspolicy=IgnoreAllFailures です',
        fixable: false,
      );
    }
    return Finding(
      id: IssueId.bcdSettings,
      title: title,
      status: FindingStatus.detected,
      detail:
          'recoveryenabled=${recoveryOff ? 'No' : 'Yes/未設定'} / bootstatuspolicy=${ignoreFailures ? 'IgnoreAllFailures' : '未設定（失敗時に WinRE へ落ちます）'}',
      fixable: true,
    );
  }

  Future<List<String>> _logNotes() async {
    final notes = <String>[];
    final ft = File(_join(winDir, ['ft3680.log']));
    if (await ft.exists()) {
      final text = await ft.readAsString().catchError((_) => '');
      final mode =
          text.toLowerCase().contains('spb') ? 'SPB' : 'ビットバン（または判定不能）';
      notes.add('ft3680.log あり: タッチドライバは起動実績あり。転送方式の痕跡: $mode');
    } else {
      notes.add('ft3680.log なし: タッチドライバはまだ一度も起動していません');
    }
    final setupErr =
        File(_join(winDir, ['Windows', 'Panther', 'setuperr.log']));
    if (await setupErr.exists()) {
      final bytes = await setupErr.readAsBytes();
      if (bytes.isNotEmpty) {
        final text = _decodeWindowsLog(bytes);
        final lines = text
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        final firstError = lines.isEmpty ? null : lines.first;
        notes.add(
            'Panther setuperr.log に記録あり（${bytes.length} バイト）${firstError == null ? '' : ': $firstError'}');
      }
    }
    return notes;
  }

  /// Panther ログは UTF-16LE（BOM 付きが多い）。素朴に判定してデコードする。
  static String _decodeWindowsLog(Uint8List bytes) {
    final isUtf16 = bytes.length >= 2 &&
        ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
            (bytes.length >= 4 && bytes[1] == 0 && bytes[3] == 0));
    if (!isUtf16) {
      return String.fromCharCodes(bytes);
    }
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  // ---- 修復（書き込み。ハイブは事前バックアップ＋読み戻し検証） ----

  /// 指定した問題 ID の修復を適用し、適用後の診断結果を返す。
  /// 適用は同一セッション内の診断で「検出」になった項目だけに行う
  /// （存在しないサービス等へ reg add で幽霊キーを作らないため）。
  Future<TroubleshootReport> applyFixes(
    Set<String> ids, {
    required void Function(String message) onProgress,
  }) async {
    _precondition();
    final hive = _hive();
    final needsHive = ids.any((i) => i != IssueId.bcdSettings);
    if (needsHive) {
      final backupPath = await hive.backup();
      onProgress('SYSTEM ハイブをバックアップしました: $backupPath');
      await hive.session(() async {
        final detected = (await _diagnoseWithHive(hive))
            .where((f) => f.status == FindingStatus.detected)
            .map((f) => f.id)
            .toSet();
        for (final id in ids.where(detected.contains)) {
          switch (id) {
            case IssueId.generalizationState:
              await hive.setDwordVerified(
                  r'Setup\Status\SysprepStatus', 'GeneralizationState', 7);
              await hive.setDwordVerified(
                  r'Setup\Status\SysprepStatus', 'CleanupState', 2);
              onProgress('GeneralizationState=7 / CleanupState=2 に修正しました');
            case IssueId.oobeIncomplete:
              await hive.setDwordVerified(
                  r'Setup\Status\ChildCompletion', 'setup.exe', 3);
              await hive.setDwordVerified('Setup', 'SystemSetupInProgress', 0);
              await hive.setDwordVerified('Setup', 'SetupType', 0);
              await hive.setStringVerified('Setup', 'CmdLine', '');
              onProgress('OOBE を完了扱いにしました（ChildCompletion=3）');
            case IssueId.qcTreeStart:
              await hive.setDwordVerified(
                  r'ControlSet001\Services\QcTrEE', 'Start', 4);
              onProgress('QcTrEE の Start を 4 にしました');
            case IssueId.qci2cStart:
              await hive.setDwordVerified(
                  r'ControlSet001\Services\qci2c', 'Start', 4);
              onProgress('qci2c の Start を 4 にしました');
            case IssueId.subsystemConfigFlags:
              await _fixSubsystemConfigFlags(hive);
              onProgress('サブシステム ConfigFlags を finalize 相当にしました');
          }
        }
      });
    }
    if (ids.contains(IssueId.bcdSettings)) {
      final bcd = await _checkBcd();
      if (bcd.status == FindingStatus.detected) {
        // ハイブ側と同様、編集前にストアをファイルごと退避する（H2）。
        final backupPath =
            '$_bcdFile.bak-${DateTime.now().millisecondsSinceEpoch}';
        await File(_bcdFile).copy(backupPath);
        onProgress('BCD をバックアップしました: $backupPath');
        await _fixBcd();
        onProgress('BCD の recoveryenabled / bootstatuspolicy を修正しました');
      }
    }
    return diagnose();
  }

  Future<void> _fixSubsystemConfigFlags(OfflineHive hive) async {
    for (final entry in _subsys.entries) {
      final instances = await _instances(hive, entry.key);
      for (final inst in instances) {
        await hive.setDwordVerified(
          'ControlSet001\\Enum\\ACPI\\${entry.key}\\$inst',
          'ConfigFlags',
          entry.value,
        );
      }
    }
  }

  Future<void> _fixBcd() async {
    Future<void> setBcd(String name, String value) async {
      final r = await runner.run(
          'bcdedit', ['/store', _bcdFile, '/set', '{default}', name, value]);
      if (!r.ok) {
        throw StateError('BCD の $name 設定に失敗しました: ${r.stderrText}');
      }
    }

    await setBcd('recoveryenabled', 'No');
    await setBcd('bootstatuspolicy', 'IgnoreAllFailures');
    // 書き込み後の読み戻し検証: 再度列挙して detected のままなら失敗扱い
    // （UI の表示どおり「各値は書き込み後に読み戻して検証」する）。
    final after = await _checkBcd();
    if (after.status == FindingStatus.detected) {
      throw StateError('BCD の読み戻し検証に失敗しました: ${after.detail}');
    }
  }
}
