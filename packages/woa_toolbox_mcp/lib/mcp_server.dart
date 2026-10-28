import 'dart:async';
import 'dart:convert';

import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// WoA Toolbox の読み取り専用 MCP サーバー（設計書 §5.7）。
///
/// - stdout は JSON-RPC 専用。ログはすべて stderr（ToolLogger の既定）。
/// - 書き込み系ツールはまだ存在しない。計画系・実行系は IPC 承認経路
///   （Phase 3 後半）が完成してから追加する。
class McpServer {
  McpServer(this._runner, {ToolLogger? logger})
      : _logger = logger ?? ToolLogger(sink: LogSink.stderr);

  final CommandRunner _runner;
  final ToolLogger _logger;

  static const protocolVersion = '2024-11-05';

  static const toolDefinitions = [
    {
      'name': 'list_devices',
      'description':
          'adb / fastboot で接続中の端末を列挙する（読み取り専用）。',
      'inputSchema': {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_gpt_layout',
      'description':
          '指定シリアルの端末の GPT を読み、レイアウト種別（android / woa / unknown）、'
          'プライマリとバックアップの整合、パーティション一覧を返す（読み取り専用）。'
          'Recovery / Android モードの端末でのみ使える。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {
            'type': 'string',
            'description': '対象端末のシリアル（list_devices で取得）',
          },
        },
        'required': ['serial'],
        'additionalProperties': false,
      },
    },
  ];

  /// JSON-RPC メッセージ1件を処理し、応答（通知なら null）を返す。
  Future<Map<String, Object?>?> handleMessage(
      Map<String, Object?> message) async {
    final method = message['method'];
    final id = message['id'];
    if (method is! String) {
      return id == null ? null : _error(id, -32600, 'Invalid Request');
    }
    final isNotification = id == null;
    try {
      switch (method) {
        case 'initialize':
          return _result(id, {
            'protocolVersion': protocolVersion,
            'capabilities': {
              'tools': <String, Object?>{},
            },
            'serverInfo': {'name': 'woa-toolbox', 'version': '0.1.0'},
          });
        case 'ping':
          return _result(id, <String, Object?>{});
        case 'tools/list':
          return _result(id, {'tools': toolDefinitions});
        case 'tools/call':
          final params = message['params'];
          if (params is! Map<String, Object?>) {
            return _error(id, -32602, 'Invalid params');
          }
          final result = await _callTool(params);
          return _result(id, result);
        default:
          // 通知は無言で無視、リクエストは Method not found。
          return isNotification ? null : _error(id, -32601, 'Method not found: $method');
      }
    } catch (e) {
      _logger.error('リクエスト処理中にエラー: $e');
      return isNotification ? null : _error(id, -32000, e.toString());
    }
  }

  Map<String, Object?> _result(Object? id, Map<String, Object?> result) =>
      {'jsonrpc': '2.0', 'id': id, 'result': result};

  Map<String, Object?> _error(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  Future<Map<String, Object?>> _callTool(Map<String, Object?> params) async {
    final name = params['name'];
    final args =
        (params['arguments'] as Map<String, Object?>?) ?? const {};
    try {
      final Object? payload = switch (name) {
        'list_devices' => await _listDevices(),
        'get_gpt_layout' => await _getGptLayout(args),
        _ => throw ArgumentError('未知のツールです: $name'),
      };
      return {
        'content': [
          {'type': 'text', 'text': jsonEncode(payload)},
        ],
        'isError': false,
      };
    } catch (e) {
      // ツール実行の失敗は JSON-RPC エラーではなく isError で返す（MCP の慣例）。
      return {
        'content': [
          {'type': 'text', 'text': e.toString()},
        ],
        'isError': true,
      };
    }
  }

  Future<Object?> _listDevices() async {
    final devices = await DeviceProbe(_runner).probe();
    return {
      'devices': [
        for (final d in devices)
          {
            'serial': d.serial,
            'mode': d.mode.name,
            if (d.product != null) 'product': d.product,
          },
      ],
    };
  }

  Future<Object?> _getGptLayout(Map<String, Object?> args) async {
    final serial = args['serial'];
    if (serial is! String || serial.isEmpty) {
      throw ArgumentError('serial 引数が必要です');
    }
    final devices = await DeviceProbe(_runner).probe();
    final device = devices.where((d) => d.serial == serial).firstOrNull;
    if (device == null) {
      throw StateError('端末が見つかりません: $serial');
    }
    if (device.mode != DeviceMode.recovery &&
        device.mode != DeviceMode.android) {
      throw StateError(
          'GPT 読み取りは Recovery / Android モードでのみ可能です（現在: ${device.mode.name}）');
    }
    final adb = AdbClient(_runner);
    final info = await adb.blockInfo(serial);
    final reader = AdbLbaReader(adb, serial, info);
    final both = await GptReader.readBoth(reader);
    final table = both.primary;
    return {
      'serial': serial,
      'layout': classifyLayout(table).name,
      'gptConsistent': both.consistent,
      'sectorSize': table.sectorSize,
      'totalLbas': info.totalLbas,
      'diskGuid': table.header.diskGuid,
      'fingerprint': table.fingerprint,
      'partitions': [
        for (final p in table.partitions)
          {
            'name': p.name,
            'firstLba': p.firstLba,
            'lastLba': p.lastLba,
            'sizeBytes': p.sizeBytes(table.sectorSize),
          },
      ],
    };
  }
}
