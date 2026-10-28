import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdoutBytes,
    required this.stderrText,
  });

  final int exitCode;
  final Uint8List stdoutBytes;
  final String stderrText;

  String get stdoutText => utf8.decode(stdoutBytes, allowMalformed: true);

  bool get ok => exitCode == 0;
}

/// コマンド実行の抽象化（設計書 §7：シェル文字列を連結せず argv で渡す）。
abstract interface class CommandRunner {
  Future<CommandResult> run(String executable, List<String> args);
}

/// dart:io の Process を使う実装。stdout はバイト列のまま受け取る
/// （バイナリ転送で改行変換等が混ざらないようにするため）。
class ProcessCommandRunner implements CommandRunner {
  const ProcessCommandRunner();

  @override
  Future<CommandResult> run(String executable, List<String> args) async {
    final process = await Process.start(executable, args, runInShell: false);
    final stdoutFuture = process.stdout
        .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk))
        .then((b) => b.takeBytes());
    final stderrFuture = process.stderr
        .transform(utf8.decoder)
        .fold<StringBuffer>(StringBuffer(), (b, s) => b..write(s))
        .then((b) => b.toString());
    final results = await Future.wait([stdoutFuture, stderrFuture]);
    final exitCode = await process.exitCode;
    return CommandResult(
      exitCode: exitCode,
      stdoutBytes: results[0] as Uint8List,
      stderrText: results[1] as String,
    );
  }
}
