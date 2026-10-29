import 'dart:io';

import '../device/command_runner.dart';

/// オフラインの SYSTEM ハイブを `reg.exe` 経由で読み書きする薄いラッパー
/// （DESIGN.md §12）。マウント名は呼び出し側で一意に保つこと。
/// 書き込みは必ず呼び出し側が読み戻して検証する前提で、
/// ここでは set した値をその場で query し直すところまで面倒を見る。
class OfflineHive {
  OfflineHive({
    required this.runner,
    required this.hiveFile,
    this.mountName = 'WOA_OFF',
  });

  final CommandRunner runner;

  /// ハイブファイルのホスト側パス（例: `R:\Windows\System32\config\SYSTEM`）。
  final String hiveFile;

  final String mountName;

  bool _loaded = false;
  bool get loaded => _loaded;

  String key(String rel) => 'HKLM\\$mountName\\$rel';

  /// reg.exe の出力で使われる正規化されたルート名。
  /// 入力は短い `HKLM` でも、出力のキーヘッダー/サブキー行は
  /// 必ず `HKEY_LOCAL_MACHINE\...` になる（実機 reg.exe の挙動）。
  String canonicalKey(String rel) => 'HKEY_LOCAL_MACHINE\\$mountName\\$rel';

  Future<void> load() async {
    if (_loaded) return;
    final r = await runner.run('reg', ['load', 'HKLM\\$mountName', hiveFile]);
    if (!r.ok) {
      throw StateError('SYSTEM ハイブのロードに失敗しました: ${r.stderrText}');
    }
    _loaded = true;
  }

  Future<void> unload() async {
    if (!_loaded) return;
    await runner.run('reg', ['unload', 'HKLM\\$mountName']);
    _loaded = false;
  }

  /// load → body → unload を保証する。例外時も unload を試みる。
  Future<T> session<T>(Future<T> Function() body) async {
    await load();
    try {
      return await body();
    } finally {
      await unload();
    }
  }

  /// 編集前にハイブファイルを `<file>.bak-<epoch ms>` へ複製する。
  /// 戻り値はバックアップ先パス。
  Future<String> backup() async {
    final dest = '$hiveFile.bak-${DateTime.now().millisecondsSinceEpoch}';
    await File(hiveFile).copy(dest);
    return dest;
  }

  /// DWORD 値を読む。キー/値が無い、または読めない場合は null。
  Future<int?> queryDword(String relKey, String valueName) async {
    final r = await runner.run('reg', ['query', key(relKey), '/v', valueName]);
    if (!r.ok) return null;
    final pattern = RegExp(
      '^\\s+${RegExp.escape(valueName)}\\s+REG_DWORD\\s+0x([0-9a-fA-F]+)',
      multiLine: true,
    );
    final m = pattern.firstMatch(r.stdoutText);
    return m == null ? null : int.parse(m.group(1)!, radix: 16);
  }

  /// REG_SZ 値を読む。無い場合は null（空文字列は '' を返す）。
  Future<String?> queryString(String relKey, String valueName) async {
    final r = await runner.run('reg', ['query', key(relKey), '/v', valueName]);
    if (!r.ok) return null;
    final pattern = RegExp(
      '^\\s+${RegExp.escape(valueName)}\\s+REG_SZ\\s*(.*)\$',
      multiLine: true,
    );
    final m = pattern.firstMatch(r.stdoutText);
    return m?.group(1)?.trim();
  }

  /// DWORD を書き、読み戻して一致を確認する。不一致は StateError。
  Future<void> setDwordVerified(
      String relKey, String valueName, int value) async {
    final r = await runner.run('reg', [
      'add',
      key(relKey),
      '/v',
      valueName,
      '/t',
      'REG_DWORD',
      '/d',
      '$value',
      '/f',
    ]);
    if (!r.ok) {
      throw StateError('$relKey\\$valueName の書き込みに失敗しました: ${r.stderrText}');
    }
    final back = await queryDword(relKey, valueName);
    if (back != value) {
      throw StateError(
          '$relKey\\$valueName の読み戻し検証に失敗しました（期待 $value / 実際 $back）');
    }
  }

  /// REG_SZ を書き、読み戻して一致を確認する。
  Future<void> setStringVerified(
      String relKey, String valueName, String value) async {
    final r = await runner.run('reg', [
      'add',
      key(relKey),
      '/v',
      valueName,
      '/t',
      'REG_SZ',
      '/d',
      value,
      '/f',
    ]);
    if (!r.ok) {
      throw StateError('$relKey\\$valueName の書き込みに失敗しました: ${r.stderrText}');
    }
    final back = await queryString(relKey, valueName);
    if ((back ?? '') != value) {
      throw StateError(
          '$relKey\\$valueName の読み戻し検証に失敗しました（期待 "$value" / 実際 "$back"）');
    }
  }

  /// 直下のサブキー名一覧を返す。キーが無い場合は空リスト。
  /// クエリ自体の失敗（キー不存在以外）は空リストで握り潰さず
  /// StateError にする（呼び出し側が「対象外」と誤判定しないため）。
  Future<List<String>> subkeys(String relKey) async {
    final r = await runner.run('reg', ['query', key(relKey)]);
    if (!r.ok) {
      // reg.exe の「キー/値が見つからない」は正常な不存在として扱う。
      final text = '${r.stdoutText}\n${r.stderrText}';
      if (text.contains('unable to find')) return const [];
      throw StateError('サブキーの列挙に失敗しました ($relKey): ${r.stderrText.trim()}');
    }
    // 出力行の接頭辞は正規化された HKEY_LOCAL_MACHINE 形式。
    // 実装差に備えて短縮形 HKLM も受理する。
    final prefixes = <String>[
      '${canonicalKey(relKey)}\\',
      '${key(relKey)}\\',
    ];
    final names = <String>[];
    for (final line in r.stdoutText.split('\n')) {
      final t = line.trim();
      for (final prefix in prefixes) {
        if (t.startsWith(prefix)) {
          final rest = t.substring(prefix.length);
          if (!rest.contains('\\')) names.add(rest);
          break;
        }
      }
    }
    return names;
  }
}
