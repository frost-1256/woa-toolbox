import 'dart:io';

/// ログの出力先。MCP モードでは stdout を JSON-RPC 専用にするため
/// 必ず stderr を使う（設計書 §5.7）。
enum LogSink { stderr, stdout, memory }

class LogRecord {
  LogRecord(this.time, this.level, this.message);
  final DateTime time;
  final String level;
  final String message;
  @override
  String toString() =>
      '[${time.toIso8601String()}] $level $message';
}

/// 出力先を切り替えられる単純なロガー。
/// GUI は memory シンクで受けて画面に出し、CLI/MCP は stderr に出す。
class ToolLogger {
  ToolLogger({this.sink = LogSink.stderr, this.memoryCapacity = 2000});

  LogSink sink;
  final int memoryCapacity;
  final List<LogRecord> _memory = [];

  List<LogRecord> get records => List.unmodifiable(_memory);

  void info(String message) => _log('INFO', message);
  void warn(String message) => _log('WARN', message);
  void error(String message) => _log('ERROR', message);

  /// 実行コマンドの記録（argv 形式でそのまま残す）。
  void command(List<String> argv) => _log('CMD', argv.join(' '));

  void _log(String level, String message) {
    final record = LogRecord(DateTime.now(), level, message);
    switch (sink) {
      case LogSink.stderr:
        stderr.writeln(record);
      case LogSink.stdout:
        stdout.writeln(record);
      case LogSink.memory:
        _memory.add(record);
        if (_memory.length > memoryCapacity) {
          _memory.removeRange(0, _memory.length - memoryCapacity);
        }
    }
  }
}
