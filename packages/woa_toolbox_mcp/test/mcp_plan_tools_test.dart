import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';
import 'package:woa_toolbox_mcp/mcp_server.dart';

/// fastboot モードの端末だけが見えるフェイク。
class FastbootFakeRunner implements CommandRunner {
  @override
  Future<CommandResult> run(String executable, List<String> args) async {
    if (executable == 'adb' && args.contains('devices')) {
      return CommandResult(
        exitCode: 0,
        stdoutBytes: Uint8List.fromList(utf8.encode('List of devices attached\n')),
        stderrText: '',
      );
    }
    if (executable == 'fastboot' && args.contains('devices')) {
      return CommandResult(
        exitCode: 0,
        stdoutBytes: Uint8List(0),
        stderrText: 'abcd1234\tfastboot\n',
      );
    }
    return CommandResult(
        exitCode: 1, stdoutBytes: Uint8List(0), stderrText: 'unexpected');
  }
}

Future<Map<String, Object?>> callTool(
    McpServer server, String name, Map<String, Object?> arguments) async {
  final res = await server.handleMessage({
    'jsonrpc': '2.0',
    'id': 99,
    'method': 'tools/call',
    'params': {'name': name, 'arguments': arguments},
  });
  final result = res!['result'] as Map<String, Object?>;
  final content = (result['content'] as List).first as Map<String, Object?>;
  return {
    'isError': result['isError'],
    'text': content['text'],
    if (result['isError'] != true)
      'payload': jsonDecode(content['text'] as String),
  };
}

void main() {
  late McpServer server;
  setUp(() {
    server = McpServer(FastbootFakeRunner(),
        logger: ToolLogger(sink: LogSink.memory));
  });

  test('tools/list に計画系と execute_plan が含まれる', () async {
    final res = await server.handleMessage({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
      'params': <String, Object?>{},
    });
    final tools =
        (res!['result'] as Map<String, Object?>)['tools'] as List;
    final names = tools.map((t) => (t as Map)['name']).toSet();
    expect(names, containsAll([
      'plan_backup',
      'plan_restore_gpt',
      'plan_restore_partition',
      'plan_return_to_android',
      'plan_fastboot_boot',
      'execute_plan',
      'get_backup_manifest',
      'get_operation_log',
    ]));
    expect(tools.length, 12);
  });

  test('plan_fastboot_boot → execute_plan は approval_unavailable', () async {
    final img = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}boot_test.img');
    await img.writeAsBytes(
        [...utf8.encode('ANDROID!'), ...List.filled(100, 0)]);
    addTearDown(() => img.delete());

    final planned = await callTool(server, 'plan_fastboot_boot', {
      'serial': 'abcd1234',
      'imagePath': img.path,
    });
    expect(planned['isError'], isFalse);
    final payload = planned['payload'] as Map<String, Object?>;
    expect(payload['kind'], 'fastbootBoot');
    final planId = payload['planId'] as String;

    final executed =
        await callTool(server, 'execute_plan', {'planId': planId});
    expect(executed['isError'], isFalse);
    final result = executed['payload'] as Map<String, Object?>;
    expect(result['status'], 'approval_unavailable');

    final unknown =
        await callTool(server, 'execute_plan', {'planId': 'plan-nope'});
    expect(unknown['isError'], isTrue);
  });

  test('不正なイメージでは計画が作れない', () async {
    final img = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}bad.img');
    await img.writeAsBytes(List.filled(64, 1));
    addTearDown(() => img.delete());
    final planned = await callTool(server, 'plan_fastboot_boot', {
      'serial': 'abcd1234',
      'imagePath': img.path,
    });
    expect(planned['isError'], isTrue);
  });

  test('get_backup_manifest と get_operation_log', () async {
    final dir = await Directory.systemTemp.createTemp('woa_mcp_manifest');
    addTearDown(() => dir.delete(recursive: true));
    final manifest = BackupManifest(
      deviceSerial: 'abcd1234',
      productDevice: 'spacewar',
      createdAt: DateTime.utc(2026, 10, 29),
      layoutFingerprint: 'fp',
      files: const [],
    );
    await File('${dir.path}${Platform.pathSeparator}manifest.json')
        .writeAsString(jsonEncode(manifest.toJson()));

    final got =
        await callTool(server, 'get_backup_manifest', {'path': dir.path});
    expect(got['isError'], isFalse);
    final payload = got['payload'] as Map<String, Object?>;
    expect((payload['manifest'] as Map)['deviceSerial'], 'abcd1234');

    final log = await callTool(server, 'get_operation_log', {});
    final lines = (log['payload'] as Map)['lines'] as List;
    expect(lines, isNotEmpty);
  });
}
