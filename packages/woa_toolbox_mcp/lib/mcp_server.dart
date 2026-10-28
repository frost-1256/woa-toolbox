import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// WoA Toolbox の MCP サーバー（設計書 §5.7）。
///
/// - stdout は JSON-RPC 専用。ログはすべて stderr（ToolLogger の既定）。
/// - 読み取り系と計画系（plan_*）を提供する。計画はこのプロセス内に
///   登録され、planId で参照できる。
/// - execute_plan は GUI での人間承認（ローカル IPC）が前提。
///   IPC が未実装の間は approval_unavailable を返し、MCP からは
///   一切書き込みを実行しない。
class McpServer {
  McpServer(this._runner, {ToolLogger? logger})
      : _logger = logger ?? ToolLogger(sink: LogSink.stderr) {
    _note('MCP サーバーを起動しました');
  }

  final CommandRunner _runner;
  final ToolLogger _logger;

  static const protocolVersion = '2024-11-05';
  static const _planner = OperationPlanner();

  final Map<String, OperationPlan> _plans = {};
  final List<String> _sessionLog = [];

  void _note(String line) {
    _sessionLog.add('${DateTime.now().toIso8601String()} $line');
    _logger.info(line);
  }

  static Map<String, Object?> _schema(
          Map<String, Object?> properties, List<String> required) =>
      {
        'type': 'object',
        'properties': properties,
        'required': required,
        'additionalProperties': false,
      };

  static const _serialProp = {
    'type': 'string',
    'description': '対象端末のシリアル（list_devices で取得）',
  };
  static const _backupDirProp = {
    'type': 'string',
    'description': 'バックアップフォルダ（manifest.json を含む）のパス',
  };

  static final toolDefinitions = [
    {
      'name': 'list_devices',
      'description': 'adb / fastboot で接続中の端末を列挙する（読み取り専用）。',
      'inputSchema': _schema(const {}, const []),
    },
    {
      'name': 'get_device_status',
      'description': '端末の状態（モード、製品名）を返す。serial 省略時は全端末。',
      'inputSchema': _schema(const {'serial': _serialProp}, const []),
    },
    {
      'name': 'get_gpt_layout',
      'description':
          '指定シリアルの端末の GPT を読み、レイアウト種別、両コピーの整合、'
          'パーティション一覧を返す（読み取り専用）。',
      'inputSchema': _schema(const {'serial': _serialProp}, const ['serial']),
    },
    {
      'name': 'list_partitions',
      'description': '指定シリアルの端末のパーティション一覧を返す（読み取り専用）。',
      'inputSchema': _schema(const {'serial': _serialProp}, const ['serial']),
    },
    {
      'name': 'get_backup_manifest',
      'description': 'バックアップの manifest.json を読み、内容を返す（読み取り専用）。',
      'inputSchema': _schema(
        const {
          'path': {
            'type': 'string',
            'description': 'manifest.json のパス、またはバックアップフォルダのパス',
          },
        },
        const ['path'],
      ),
    },
    {
      'name': 'get_operation_log',
      'description': 'この MCP セッションの操作ログを返す。',
      'inputSchema': _schema(const {}, const []),
    },
    {
      'name': 'plan_backup',
      'description':
          'バックアップの計画を作成する。partitions を省略すると GPT 全体、'
          '指定するとそのパーティション群。計画は実行されない。',
      'inputSchema': _schema(
        const {
          'serial': _serialProp,
          'partitions': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '対象パーティション名（省略時は GPT バックアップ）',
          },
        },
        const ['serial'],
      ),
    },
    {
      'name': 'plan_restore_gpt',
      'description':
          'GPT 復元の計画を作成する（diff 付き）。バックアップフォルダと、'
          '現在の端末 GPT を突き合わせて検証する。計画は実行されない。',
      'inputSchema': _schema(
        const {'serial': _serialProp, 'backupDir': _backupDirProp},
        const ['serial', 'backupDir'],
      ),
    },
    {
      'name': 'plan_restore_partition',
      'description':
          'パーティション書き戻しの計画を作成する。manifest の端末一致と'
          'サイズ一致を検証する。計画は実行されない。',
      'inputSchema': _schema(
        const {
          'serial': _serialProp,
          'backupDir': _backupDirProp,
          'partition': {
            'type': 'string',
            'description': '書き戻すパーティション名（例: persist）',
          },
        },
        const ['serial', 'backupDir', 'partition'],
      ),
    },
    {
      'name': 'plan_return_to_android',
      'description':
          '「Android（LineageOS）に戻す」ウィザードの計画を作成する'
          '（GPT 復元＋sideload の手順と diff）。計画は実行されない。',
      'inputSchema': _schema(
        const {
          'serial': _serialProp,
          'backupDir': _backupDirProp,
          'lineageZip': {
            'type': 'string',
            'description': 'LineageOS の zip ファイルのパス',
          },
        },
        const ['serial', 'backupDir', 'lineageZip'],
      ),
    },
    {
      'name': 'plan_fastboot_boot',
      'description':
          'fastboot boot（一時起動）の計画を作成する。イメージの妥当性を'
          '検証する。計画は実行されない。',
      'inputSchema': _schema(
        const {
          'serial': _serialProp,
          'imagePath': {
            'type': 'string',
            'description': 'ブートイメージ（.img）のパス',
          },
        },
        const ['serial', 'imagePath'],
      ),
    },
    {
      'name': 'execute_plan',
      'description':
          '計画を実行する。実行には GUI での人間承認（ローカル IPC）が'
          '必要で、未接続の場合は approval_unavailable を返す。',
      'inputSchema': _schema(
        const {
          'planId': {
            'type': 'string',
            'description': 'plan_* ツールが返した planId',
          },
        },
        const ['planId'],
      ),
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
            'serverInfo': {'name': 'woa-toolbox', 'version': '0.2.0'},
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
          return isNotification
              ? null
              : _error(id, -32601, 'Method not found: $method');
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
        'get_device_status' => await _getDeviceStatus(args),
        'get_gpt_layout' => await _getGptLayout(args),
        'list_partitions' => await _listPartitions(args),
        'get_backup_manifest' => await _getBackupManifest(args),
        'get_operation_log' => {'lines': _sessionLog},
        'plan_backup' => await _planBackup(args),
        'plan_restore_gpt' => await _planRestoreGpt(args),
        'plan_restore_partition' => await _planRestorePartition(args),
        'plan_return_to_android' => await _planReturnToAndroid(args),
        'plan_fastboot_boot' => await _planFastbootBoot(args),
        'execute_plan' => _executePlan(args),
        _ => throw ArgumentError('未知のツールです: $name'),
      };
      _note('ツール $name を実行しました');
      return {
        'content': [
          {'type': 'text', 'text': jsonEncode(payload)},
        ],
        'isError': false,
      };
    } catch (e) {
      // ツール実行の失敗は JSON-RPC エラーではなく isError で返す（MCP の慣例）。
      _note('ツール $name が失敗しました: $e');
      return {
        'content': [
          {'type': 'text', 'text': e.toString()},
        ],
        'isError': true,
      };
    }
  }

  // ---- 共通ヘルパー ----

  String _requireSerial(Map<String, Object?> args) {
    final serial = args['serial'];
    if (serial is! String || serial.isEmpty) {
      throw ArgumentError('serial 引数が必要です');
    }
    return serial;
  }

  Future<ToolboxDevice> _requireDevice(String serial) async {
    final devices = await DeviceProbe(_runner).probe();
    for (final d in devices) {
      if (d.serial == serial) return d;
    }
    throw StateError('端末が見つかりません: $serial');
  }

  Future<
      ({
        GptTable primary,
        GptTable backup,
        bool consistent,
        int totalLbas,
      })> _readGpt(String serial) async {
    final device = await _requireDevice(serial);
    if (device.mode != DeviceMode.recovery &&
        device.mode != DeviceMode.android) {
      throw StateError(
          'GPT 読み取りは Recovery / Android モードでのみ可能です（現在: ${device.mode.name}）');
    }
    final adb = AdbClient(_runner);
    final info = await adb.blockInfo(serial);
    final reader = AdbLbaReader(adb, serial, info);
    final both = await GptReader.readBoth(reader);
    return (
      primary: both.primary,
      backup: both.backup,
      consistent: both.consistent,
      totalLbas: info.totalLbas,
    );
  }

  Future<({BackupManifest manifest, String dir})> _loadManifest(
      String path) async {
    final file = path.endsWith('.json')
        ? File(path)
        : File('$path${Platform.pathSeparator}manifest.json');
    if (!await file.exists()) {
      throw ArgumentError('manifest.json が見つかりません: ${file.path}');
    }
    final manifest = BackupManifest.decode(await file.readAsString());
    return (manifest: manifest, dir: file.parent.path);
  }

  Future<({GptTable primary, GptTable backup})> _loadRestoreTables(
      String dir, int sectorSize, int totalLbas) async {
    final sep = Platform.pathSeparator;
    final primaryFile = File('$dir${sep}gpt_primary.bin');
    final backupFile = File('$dir${sep}gpt_backup.bin');
    if (!await primaryFile.exists() || !await backupFile.exists()) {
      throw ArgumentError(
          'バックアップに GPT ファイル（gpt_primary.bin / gpt_backup.bin）がありません');
    }
    final primary = GptParser.parsePrimary(await primaryFile.readAsBytes(),
        sectorSize: sectorSize);
    final backup = GptParser.parseBackup(await backupFile.readAsBytes(),
        sectorSize: sectorSize, totalLbas: totalLbas);
    return (primary: primary, backup: backup);
  }

  Map<String, Object?> _registerPlan(OperationPlan plan) {
    _plans[plan.id] = plan;
    _note('計画を作成しました: ${plan.title} (${plan.id})');
    return planToJson(plan);
  }

  List<Map<String, Object?>> _partitionJson(GptTable table) => [
        for (final p in table.partitions)
          {
            'name': p.name,
            'firstLba': p.firstLba,
            'lastLba': p.lastLba,
            'sizeBytes': p.sizeBytes(table.sectorSize),
          },
      ];

  // ---- 読み取り系 ----

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

  Future<Object?> _getDeviceStatus(Map<String, Object?> args) async {
    final serial = args['serial'];
    if (serial is String && serial.isNotEmpty) {
      final d = await _requireDevice(serial);
      return {
        'serial': d.serial,
        'mode': d.mode.name,
        if (d.product != null) 'product': d.product,
      };
    }
    return _listDevices();
  }

  Future<Object?> _getGptLayout(Map<String, Object?> args) async {
    final serial = _requireSerial(args);
    final gpt = await _readGpt(serial);
    final table = gpt.primary;
    return {
      'serial': serial,
      'layout': classifyLayout(table).name,
      'gptConsistent': gpt.consistent,
      'sectorSize': table.sectorSize,
      'totalLbas': gpt.totalLbas,
      'diskGuid': table.header.diskGuid,
      'fingerprint': table.fingerprint,
      'partitions': _partitionJson(table),
    };
  }

  Future<Object?> _listPartitions(Map<String, Object?> args) async {
    final serial = _requireSerial(args);
    final gpt = await _readGpt(serial);
    return {'serial': serial, 'partitions': _partitionJson(gpt.primary)};
  }

  Future<Object?> _getBackupManifest(Map<String, Object?> args) async {
    final path = args['path'];
    if (path is! String || path.isEmpty) {
      throw ArgumentError('path 引数が必要です');
    }
    final loaded = await _loadManifest(path);
    return {'dir': loaded.dir, 'manifest': loaded.manifest.toJson()};
  }

  // ---- 計画系 ----

  Future<Object?> _planBackup(Map<String, Object?> args) async {
    final serial = _requireSerial(args);
    final gpt = await _readGpt(serial);
    final partitions = args['partitions'];
    final OperationPlan plan;
    if (partitions is List && partitions.isNotEmpty) {
      plan = _planner.planBackupPartitions(
        serial: serial,
        primary: gpt.primary,
        names: partitions.cast<String>(),
      );
    } else {
      plan = _planner.planBackupGpt(
        serial: serial,
        primary: gpt.primary,
        backup: gpt.backup,
        totalLbas: gpt.totalLbas,
      );
    }
    return _registerPlan(plan);
  }

  Future<Object?> _planRestoreGpt(Map<String, Object?> args) async {
    final serial = _requireSerial(args);
    final backupDir = args['backupDir'];
    if (backupDir is! String || backupDir.isEmpty) {
      throw ArgumentError('backupDir 引数が必要です');
    }
    final gpt = await _readGpt(serial);
    final loaded = await _loadManifest(backupDir);
    final tables = await _loadRestoreTables(
        loaded.dir, gpt.primary.sectorSize, gpt.totalLbas);
    final plan = _planner.planRestoreGpt(
      serial: serial,
      currentPrimary: gpt.primary,
      restorePrimary: tables.primary,
      restoreBackup: tables.backup,
      totalLbas: gpt.totalLbas,
      restorePath: loaded.dir,
    );
    return _registerPlan(plan);
  }

  Future<Object?> _planRestorePartition(Map<String, Object?> args) async {
    final serial = _requireSerial(args);
    final backupDir = args['backupDir'];
    final partition = args['partition'];
    if (backupDir is! String || backupDir.isEmpty) {
      throw ArgumentError('backupDir 引数が必要です');
    }
    if (partition is! String || partition.isEmpty) {
      throw ArgumentError('partition 引数が必要です');
    }
    final device = await _requireDevice(serial);
    final gpt = await _readGpt(serial);
    final loaded = await _loadManifest(backupDir);
    BackupFileEntry? entry;
    for (final f in loaded.manifest.files) {
      if (f.partitionName == partition) entry = f;
    }
    if (entry == null) {
      throw ArgumentError('バックアップに $partition のエントリがありません');
    }
    final plan = _planner.planRestorePartition(
      serial: serial,
      productDevice: device.product ?? '',
      currentPrimary: gpt.primary,
      manifest: loaded.manifest,
      entry: entry,
    );
    return _registerPlan(plan);
  }

  Future<Object?> _planReturnToAndroid(Map<String, Object?> args) async {
    final serial = _requireSerial(args);
    final backupDir = args['backupDir'];
    final lineageZip = args['lineageZip'];
    if (backupDir is! String || backupDir.isEmpty) {
      throw ArgumentError('backupDir 引数が必要です');
    }
    if (lineageZip is! String || lineageZip.isEmpty) {
      throw ArgumentError('lineageZip 引数が必要です');
    }
    final gpt = await _readGpt(serial);
    final loaded = await _loadManifest(backupDir);
    final tables = await _loadRestoreTables(
        loaded.dir, gpt.primary.sectorSize, gpt.totalLbas);
    final plan = await _planner.planReturnToAndroid(
      serial: serial,
      currentPrimary: gpt.primary,
      restorePrimary: tables.primary,
      restoreBackup: tables.backup,
      totalLbas: gpt.totalLbas,
      restorePath: loaded.dir,
      lineageZipPath: lineageZip,
    );
    return _registerPlan(plan);
  }

  Future<Object?> _planFastbootBoot(Map<String, Object?> args) async {
    final serial = _requireSerial(args);
    final imagePath = args['imagePath'];
    if (imagePath is! String || imagePath.isEmpty) {
      throw ArgumentError('imagePath 引数が必要です');
    }
    final device = await _requireDevice(serial);
    if (device.mode != DeviceMode.fastboot) {
      throw StateError('端末が fastboot モードではありません（現在: ${device.mode.name}）');
    }
    final plan =
        await _planner.planFastbootBoot(serial: serial, imagePath: imagePath);
    return _registerPlan(plan);
  }

  // ---- 実行（承認待ち） ----

  Map<String, Object?> _executePlan(Map<String, Object?> args) {
    final planId = args['planId'];
    if (planId is! String || planId.isEmpty) {
      throw ArgumentError('planId 引数が必要です');
    }
    final plan = _plans[planId];
    if (plan == null) {
      throw ArgumentError('計画が見つかりません: $planId');
    }
    if (plan.isExpired()) {
      _plans.remove(planId);
      throw StateError('計画の有効期限が切れています: $planId');
    }
    // 設計書 §5.7: 実行は GUI での人間承認（ローカル IPC）が必須。
    // IPC 未実装の間はここで止める。
    _note('execute_plan が承認待ちで停止しました: $planId');
    return {
      'status': 'approval_unavailable',
      'planId': planId,
      'message': '実行には WoA Toolbox GUI での人間承認（ローカル IPC）が必要です。'
          'IPC が未実装のため、MCP からの実行は無効です。GUI で同じ操作を実行してください。',
    };
  }
}
