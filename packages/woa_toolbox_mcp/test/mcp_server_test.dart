import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';
import 'package:woa_toolbox_mcp/mcp_server.dart';

/// canned な adb / fastboot 出力を返すフェイク。
class FakeRunner implements CommandRunner {
  @override
  Future<CommandResult> run(String executable, List<String> args) async {
    if (executable == 'adb' && args.contains('devices')) {
      return CommandResult(
        exitCode: 0,
        stdoutBytes: Uint8List.fromList(utf8.encode(
            'List of devices attached\nabcd1234\trecovery product:spacewar\n')),
        stderrText: '',
      );
    }
    if (executable == 'fastboot') {
      return CommandResult(
        exitCode: 0,
        stdoutBytes: Uint8List(0),
        stderrText: '',
      );
    }
    return CommandResult(
      exitCode: 1,
      stdoutBytes: Uint8List(0),
      stderrText: 'unexpected call: $executable $args',
    );
  }
}

void main() {
  final server = McpServer(FakeRunner(),
      logger: ToolLogger(sink: LogSink.memory));

  test('initialize にプロトコル情報で応答する', () async {
    final res = await server.handleMessage({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, Object?>{},
    });
    final result = res!['result'] as Map<String, Object?>;
    expect(result['protocolVersion'], McpServer.protocolVersion);
    expect((result['serverInfo'] as Map)['name'], 'woa-toolbox');
  });

  test('tools/list は読み取り専用ツールだけを返す', () async {
    final res = await server.handleMessage(
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    final tools = (res!['result'] as Map)['tools'] as List;
    final names = tools.map((t) => (t as Map)['name']).toSet();
    expect(names, {'list_devices', 'get_gpt_layout'});
  });

  test('list_devices がフェイク adb の出力を返す', () async {
    final res = await server.handleMessage({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': 'list_devices', 'arguments': <String, Object?>{}},
    });
    final result = res!['result'] as Map<String, Object?>;
    expect(result['isError'], isFalse);
    final text =
        ((result['content'] as List).first as Map)['text'] as String;
    final payload = jsonDecode(text) as Map<String, Object?>;
    final devices = payload['devices'] as List;
    expect(devices.length, 1);
    expect((devices.first as Map)['serial'], 'abcd1234');
    expect((devices.first as Map)['mode'], 'recovery');
  });

  test('未知のシリアルはツールエラー (isError) になる', () async {
    final res = await server.handleMessage({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'tools/call',
      'params': {
        'name': 'get_gpt_layout',
        'arguments': {'serial': 'nope9999'},
      },
    });
    final result = res!['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
  });

  test('通知には応答しない', () async {
    final res = await server.handleMessage(
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    expect(res, isNull);
  });

  test('未知のメソッドは -32601', () async {
    final res = await server
        .handleMessage({'jsonrpc': '2.0', 'id': 9, 'method': 'bogus/method'});
    expect((res!['error'] as Map)['code'], -32601);
  });
}
