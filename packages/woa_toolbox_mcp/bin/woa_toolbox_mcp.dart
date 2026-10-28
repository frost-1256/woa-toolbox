import 'dart:convert';
import 'dart:io';

import 'package:woa_toolbox_core/woa_toolbox_core.dart';
import 'package:woa_toolbox_mcp/mcp_server.dart';

/// stdio の MCP サーバーとして起動する。
/// stdout は JSON-RPC 専用 — バナーやログは絶対に出さない（設計書 §5.7）。
Future<void> main(List<String> args) async {
  final logger = ToolLogger(sink: LogSink.stderr);
  final server = McpServer(const ProcessCommandRunner(), logger: logger);
  logger.info('woa-toolbox MCP サーバーを起動しました（読み取り専用）');

  final lines = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  await for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (e) {
      logger.error('JSON として解釈できない入力を無視しました: $e');
      continue;
    }
    if (decoded is! Map<String, Object?>) {
      logger.error('JSON-RPC オブジェクトでない入力を無視しました');
      continue;
    }
    final response = await server.handleMessage(decoded);
    if (response != null) {
      stdout.writeln(jsonEncode(response));
      await stdout.flush();
    }
  }
}
