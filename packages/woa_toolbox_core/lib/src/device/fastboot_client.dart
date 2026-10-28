import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'command_runner.dart';

/// Android ブートイメージの検証（fastboot boot の誤爆防止）。
/// Mu-Silicium の boot.img は Android ブートイメージ形式（マジック "ANDROID!"）。
class BootImage {
  /// ファイル先頭のマジックとサイズの妥当性を検証する。
  /// 問題があれば理由を返す（問題なければ null）。
  static String? validateBytes(Uint8List bytes) {
    if (bytes.length < 8) return 'ファイルが小さすぎます';
    final magic = String.fromCharCodes(bytes.sublist(0, 8));
    if (magic != 'ANDROID!') {
      return 'Android ブートイメージのマジック (ANDROID!) がありません';
    }
    if (bytes.length > 512 * 1024 * 1024) return 'ファイルが大きすぎます';
    return null;
  }

  /// イメージの同一性を示す SHA-256 フィンガープリント。
  /// UEFI 本体は圧縮されていて中身から版を読み取れないため、
  /// 「どのビルドか」の識別はこの指紋と取得元の情報で行う。
  static String fingerprintHex(List<int> bytes) => sha256.convert(bytes).toString();

  static Future<String?> validateFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return 'ファイルが存在しません: $path';
    final length = await file.length();
    if (length < 8) return 'ファイルが小さすぎます';
    final head = await file.openRead(0, 8).fold<BytesBuilder>(
        BytesBuilder(), (b, chunk) => b..add(chunk));
    final problem = validateBytes(head.takeBytes());
    if (problem != null) return problem;
    if (length > 512 * 1024 * 1024) return 'ファイルが大きすぎます';
    return null;
  }
}

/// fastboot の操作。v1 で公開するのは一時ブート (boot) のみ。
/// flash / erase 等の書き込み系は設計書の方針どおり実装しない。
class FastbootClient {
  FastbootClient(this._runner, {this.fastbootExecutable = 'fastboot'});

  final CommandRunner _runner;
  final String fastbootExecutable;

  /// 指定イメージで一時ブートする（フラッシュはしない）。
  /// 実行前にブートイメージ形式を検証する。
  Future<CommandResult> boot(
    String serial,
    String imagePath, {
    void Function(String line)? onOutput,
  }) async {
    final problem = await BootImage.validateFile(imagePath);
    if (problem != null) {
      throw ArgumentError(problem);
    }
    final result = await _runner
        .run(fastbootExecutable, ['-s', serial, 'boot', imagePath]);
    // fastboot は経過を stderr に出す。
    for (final line in result.stderrText.split('\n')) {
      if (line.trim().isNotEmpty) onOutput?.call(line.trim());
    }
    if (!result.ok) {
      throw StateError(
          'fastboot boot が失敗しました: ${result.stderrText.trim()}');
    }
    return result;
  }

  /// 通常再起動する。
  Future<void> reboot(String serial) async {
    final result =
        await _runner.run(fastbootExecutable, ['-s', serial, 'reboot']);
    if (!result.ok) {
      throw StateError('fastboot reboot が失敗しました: ${result.stderrText.trim()}');
    }
  }

  /// ブートローダー (fastboot) へ再起動する。
  Future<void> rebootBootloader(String serial) async {
    final result = await _runner
        .run(fastbootExecutable, ['-s', serial, 'reboot-bootloader']);
    if (!result.ok) {
      throw StateError(
          'fastboot reboot-bootloader が失敗しました: ${result.stderrText.trim()}');
    }
  }
}
