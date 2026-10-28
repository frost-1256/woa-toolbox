import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// UEFI イメージライブラリの1件。
class UefiImageEntry {
  const UefiImageEntry({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
    required this.fingerprintShort,
    this.sourceLabel,
    this.memo = '',
  });
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modified;

  /// SHA-256 の先頭12桁（ビルドの同一性確認用）。
  final String fingerprintShort;

  /// 取得元の表示（例: "Actions Run #51 (3fe450a)"）。ローカル取り込みは null。
  final String? sourceLabel;

  /// ユーザーのメモ（例: 「v3.2 本番」）。
  final String memo;
}

/// アプリ全体の状態（Phase 1: 読み取り専用）。
/// 状態管理は ChangeNotifier で軽量に始める（設計書 §9 の未決定事項への暫定回答）。
class AppState extends ChangeNotifier {
  AppState() : logger = ToolLogger(sink: LogSink.memory);

  final ToolLogger logger;
  final CommandRunner _runner = const ProcessCommandRunner();

  List<ToolboxDevice> devices = [];
  ToolboxDevice? selected;
  GptTable? primaryTable;
  GptTable? backupTable;
  int? totalLbas;
  bool? gptConsistent;
  PartitionLayout? layout;
  MassStorageState? massStorage;
  bool busy = false;
  String? error;

  bool get canReadGpt {
    final mode = selected?.mode;
    return mode == DeviceMode.recovery || mode == DeviceMode.android;
  }

  // ---- 端末検出（手動＋自動ポーリング） ----

  bool autoDetect = true;
  Timer? _autoDetectTimer;
  String _deviceSignature = '';

  String _signatureOf(List<ToolboxDevice> list) =>
      list.map((d) => '${d.serial}:${d.mode.name}').join('|');

  /// 検出結果を反映する。選択中端末はシリアルで追いかけ、モードが変わったら
  /// 旧モードで読んだ状態（GPT 等）を破棄する。何か変わったら true。
  bool _applyDevices(List<ToolboxDevice> found) {
    var changed = _signatureOf(found) != _deviceSignature;
    _deviceSignature = _signatureOf(found);
    devices = found;
    final current = selected;
    if (current != null) {
      ToolboxDevice? match;
      for (final d in found) {
        if (d.serial == current.serial) {
          match = d;
          break;
        }
      }
      if (match == null) {
        selected = null;
        primaryTable = null;
        backupTable = null;
        totalLbas = null;
        gptConsistent = null;
        layout = null;
        massStorage = null;
        changed = true;
      } else if (match.mode != current.mode) {
        selected = match;
        primaryTable = null;
        backupTable = null;
        totalLbas = null;
        gptConsistent = null;
        layout = null;
        massStorage = null;
        changed = true;
        if (match.mode == DeviceMode.recovery) {
          refreshMassStorageState();
        }
      } else {
        selected = match;
      }
    }
    return changed;
  }

  Future<void> refreshDevices() async {
    await _guard(() async {
      logger.info('端末を検出しています…');
      final found = await DeviceProbe(_runner).probe();
      _applyDevices(found);
      logger.info('${found.length} 台の端末が見つかりました');
    });
  }

  void _startAutoDetect() {
    _autoDetectTimer?.cancel();
    if (!autoDetect) return;
    _autoDetectTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _autoRefresh());
  }

  Future<void> _autoRefresh() async {
    if (busy || !autoDetect) return;
    try {
      final found = await DeviceProbe(_runner).probe();
      if (_applyDevices(found)) {
        logger.info('端末構成が変わりました: '
            '${found.isEmpty ? 'なし' : found.map((d) => '${d.serial} (${d.mode.name})').join(', ')}');
        notifyListeners();
      }
    } catch (_) {
      // 自動検出の失敗は静かに無視する（手動検出ではエラーとして表示される）。
    }
  }

  Future<void> setAutoDetect(bool enabled) async {
    autoDetect = enabled;
    _settings['autoDetect'] = enabled;
    notifyListeners();
    _startAutoDetect();
    await _saveSettings();
  }

  @override
  void dispose() {
    _autoDetectTimer?.cancel();
    super.dispose();
  }

  void select(ToolboxDevice device) {
    selected = device;
    primaryTable = null;
    backupTable = null;
    totalLbas = null;
    gptConsistent = null;
    layout = null;
    massStorage = null;
    error = null;
    notifyListeners();
    if (device.mode == DeviceMode.recovery) {
      refreshMassStorageState();
    }
  }

  bool get canUseMassStorage => selected?.mode == DeviceMode.recovery;

  Future<void> refreshMassStorageState() async {
    final device = selected;
    if (device == null || !canUseMassStorage) return;
    try {
      massStorage =
          await GadgetService(_runner).massStorageState(device.serial);
      notifyListeners();
    } catch (_) {
      // 状態が読めない場合は unknown のままにする（致命的でない）。
    }
  }

  Future<void> enableMassStorage() async {
    final device = selected;
    if (device == null || !canUseMassStorage) return;
    await _guard(() async {
      logger.info('${device.serial} で Mass Storage を有効化します');
      await GadgetService(_runner).enableMassStorage(
        device.serial,
        onStep: (step) => logger.command(['adb', 'shell', step]),
      );
      massStorage = MassStorageState.on;
      logger.info(
          'Mass Storage を有効化しました。PC 側にディスクが見えるはずです。'
          '戻すときは端末を再起動して Recovery に入り直してください。');
    });
  }

  Future<void> readGpt() async {
    final device = selected;
    if (device == null || !canReadGpt) return;
    await _guard(() async {
      logger.info('${device.serial} の GPT を読み取ります');
      final adb = AdbClient(_runner);
      final info = await adb.blockInfo(device.serial);
      logger.info(
          'セクタサイズ ${info.logicalSectorSize}B / 総 LBA ${info.totalLbas}');
      final reader = AdbLbaReader(adb, device.serial, info);
      final both = await GptReader.readBoth(reader);
      primaryTable = both.primary;
      backupTable = both.backup;
      totalLbas = info.totalLbas;
      gptConsistent = both.consistent;
      layout = classifyLayout(both.primary);
      logger.info(
          'GPT 読み取り完了: ${both.primary.partitions.length} パーティション、'
          'プライマリ/バックアップ整合 = ${both.consistent}');
      if (!both.consistent) {
        logger.warn('プライマリとバックアップの GPT が一致しません');
      }
    });
  }

  // ---- UEFI イメージライブラリ / fastboot boot / Actions 取得 ----

  List<UefiImageEntry> uefiImages = [];
  String? selectedUefiImagePath;
  String githubToken = '';

  Future<Directory> _appDataDir() async {
    final String base;
    if (Platform.isWindows) {
      base = Platform.environment['APPDATA'] ??
          (await Directory.systemTemp.createTemp()).path;
    } else {
      final home = Platform.environment['HOME'] ?? '/tmp';
      base = '$home/.local/share';
    }
    final dir = Directory('$base${Platform.pathSeparator}woa-toolbox');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _uefiImagesDir() async {
    final dir = Directory(
        '${(await _appDataDir()).path}${Platform.pathSeparator}uefi-images');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _settingsFile() async =>
      File('${(await _appDataDir()).path}${Platform.pathSeparator}settings.json');

  Map<String, Object?> _settings = {};
  ThemeMode themeMode = ThemeMode.system;

  Future<void> _saveSettings() async {
    final settings = await _settingsFile();
    await settings.writeAsString(jsonEncode(_settings));
  }

  Future<void> loadUefiLibrary() async {
    try {
      final settings = await _settingsFile();
      if (await settings.exists()) {
        _settings =
            jsonDecode(await settings.readAsString()) as Map<String, Object?>;
        githubToken = (_settings['githubToken'] as String?) ?? '';
        autoDetect = (_settings['autoDetect'] as bool?) ?? true;
        themeMode = switch (_settings['themeMode'] as String?) {
          'dark' => ThemeMode.dark,
          'light' => ThemeMode.light,
          _ => ThemeMode.system,
        };
      }
    } catch (_) {
      // 設定が壊れていても起動は続ける。
    }
    await _refreshUefiImages();
    notifyListeners();
    _startAutoDetect();
  }

  Future<void> setGithubToken(String token) async {
    githubToken = token.trim();
    _settings['githubToken'] = githubToken;
    await _saveSettings();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    _settings['themeMode'] = mode.name;
    notifyListeners();
    await _saveSettings();
  }

  /// ライブラリのメタデータ（メモ・取得元）: uefi-images/library.json
  Map<String, Map<String, Object?>> _libraryMeta = {};
  bool _libraryMetaLoaded = false;

  Future<File> _libraryMetaFile() async => File(
      '${(await _uefiImagesDir()).path}${Platform.pathSeparator}library.json');

  Future<void> _loadLibraryMeta() async {
    try {
      final file = await _libraryMetaFile();
      if (await file.exists()) {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, Object?>;
        _libraryMeta = {
          for (final e in json.entries)
            e.key: (e.value as Map).cast<String, Object?>(),
        };
      }
    } catch (_) {
      _libraryMeta = {};
    }
    _libraryMetaLoaded = true;
  }

  Future<void> _saveLibraryMeta() async {
    final file = await _libraryMetaFile();
    await file.writeAsString(jsonEncode(_libraryMeta));
  }

  Future<void> _refreshUefiImages() async {
    if (!_libraryMetaLoaded) await _loadLibraryMeta();
    final dir = await _uefiImagesDir();
    final entries = <UefiImageEntry>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.img')) {
        final stat = await entity.stat();
        final name = entity.uri.pathSegments.last;
        final bytes = await entity.readAsBytes();
        final meta = _libraryMeta[name] ?? const {};
        entries.add(UefiImageEntry(
          name: name,
          path: entity.path,
          sizeBytes: stat.size,
          modified: stat.modified,
          fingerprintShort:
              BootImage.fingerprintHex(bytes).substring(0, 12),
          sourceLabel: meta['sourceLabel'] as String?,
          memo: (meta['memo'] as String?) ?? '',
        ));
      }
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    uefiImages = entries;
    if (selectedUefiImagePath != null &&
        !entries.any((e) => e.path == selectedUefiImagePath)) {
      selectedUefiImagePath = null;
    }
  }

  /// ライブラリからイメージを削除する（ファイルとメタデータ）。
  Future<void> deleteUefiImage(String path) async {
    await _guard(() async {
      final name = path.split(RegExp(r'[\\/]')).last;
      final file = File(path);
      if (await file.exists()) await file.delete();
      _libraryMeta.remove(name);
      await _saveLibraryMeta();
      if (selectedUefiImagePath == path) selectedUefiImagePath = null;
      logger.info('UEFI イメージを削除しました: $name');
      await _refreshUefiImages();
    });
  }

  /// イメージにメモを付ける（「v3.2 本番」など）。
  Future<void> setUefiMemo(String path, String memo) async {
    final name = path.split(RegExp(r'[\\/]')).last;
    final meta = _libraryMeta[name] ??= {};
    meta['memo'] = memo;
    await _saveLibraryMeta();
    await _refreshUefiImages();
    notifyListeners();
  }

  void selectUefiImage(String path) {
    selectedUefiImagePath = path;
    notifyListeners();
  }

  /// ローカルファイルを取り込む（形式検証を通ったものだけ）。
  Future<void> addUefiImage(String sourcePath) async {
    await _guard(() async {
      final problem = await BootImage.validateFile(sourcePath);
      if (problem != null) {
        throw StateError('UEFI イメージとして使えません: $problem');
      }
      final dir = await _uefiImagesDir();
      final name = sourcePath.split(RegExp(r'[\\/]')).last;
      var target = File('${dir.path}${Platform.pathSeparator}$name');
      if (await target.exists()) {
        final stem = name.replaceAll(RegExp(r'\.img$'), '');
        target = File(
            '${dir.path}${Platform.pathSeparator}$stem-${DateTime.now().millisecondsSinceEpoch}.img');
      }
      await File(sourcePath).copy(target.path);
      logger.info('UEFI イメージを取り込みました: ${target.uri.pathSegments.last}');
      await _refreshUefiImages();
      selectedUefiImagePath = target.path;
    });
  }

  /// Mu-Silicium の Actions から最新の成功 run の UEFI を取得する。
  Future<void> downloadLatestUefi() async {
    await _guard(() async {
      logger.info('GitHub Actions の最新 UEFI を取得します…');
      final client = GitHubActionsClient(token: githubToken);
      final result = await client.fetchLatestArtifactFile(
        owner: 'frost-1256',
        repo: 'Mu-Silicium',
        workflowFileName: 'spacewar.yml',
        artifactName: 'uefi-spacewar',
      );
      final problem = BootImage.validateBytes(result.fileBytes);
      if (problem != null) {
        throw StateError('取得したイメージが不正です: $problem');
      }
      final dir = await _uefiImagesDir();
      final name = 'Mu-spacewar-run${result.run.runNumber}.img';
      final target = File('${dir.path}${Platform.pathSeparator}$name');
      await target.writeAsBytes(result.fileBytes);
      final meta = _libraryMeta[name] ??= {};
      meta['sourceLabel'] =
          'Actions Run #${result.run.runNumber} (${result.run.headSha})';
      await _saveLibraryMeta();
      logger.info(
          'Run #${result.run.runNumber} (${result.run.headSha}) の UEFI を保存しました: $name');
      await _refreshUefiImages();
      selectedUefiImagePath = target.path;
    });
  }

  // ---- 再起動系 ----

  bool get _selectedIsAdb =>
      selected != null &&
      selected!.mode != DeviceMode.fastboot &&
      selected!.mode != DeviceMode.unauthorized &&
      selected!.mode != DeviceMode.offline &&
      selected!.mode != DeviceMode.unknown;

  Future<void> _afterReboot() async {
    selected = null;
    primaryTable = null;
    layout = null;
    massStorage = null;
    notifyListeners();
    await Future<void>.delayed(const Duration(seconds: 6));
    await refreshDevices();
  }

  /// ブートローダー (fastboot) へ再起動する。
  Future<void> rebootToBootloader() async {
    final device = selected;
    if (device == null) return;
    await _guard(() async {
      logger.info('${device.serial} をブートローダーへ再起動します');
      if (device.mode == DeviceMode.fastboot) {
        await FastbootClient(_runner).rebootBootloader(device.serial);
      } else if (_selectedIsAdb) {
        await AdbClient(_runner).reboot(device.serial, target: 'bootloader');
      } else {
        throw StateError('このモードでは実行できません');
      }
      logger.info('再起動しました。fastboot モードで検出されるはずです');
    });
    await _afterReboot();
  }

  /// Recovery へ再起動する（Recovery モード自身では出さない）。
  Future<void> rebootToRecovery() async {
    final device = selected;
    if (device == null || device.mode == DeviceMode.recovery) return;
    await _guard(() async {
      logger.info('${device.serial} を Recovery へ再起動します');
      if (device.mode == DeviceMode.fastboot) {
        await FastbootClient(_runner).rebootRecovery(device.serial);
      } else if (_selectedIsAdb) {
        await AdbClient(_runner).reboot(device.serial, target: 'recovery');
      } else {
        throw StateError('このモードでは実行できません');
      }
    });
    await _afterReboot();
  }

  bool get canBootUefi =>
      selected?.mode == DeviceMode.fastboot && selectedUefiImagePath != null;

  bool get canBootFromRecovery =>
      selected?.mode == DeviceMode.recovery && selectedUefiImagePath != null;

  /// Recovery の端末をブートローダーへ再起動し、そのまま UEFI を一時ブートする。
  Future<void> bootFromRecovery() async {
    final device = selected;
    final imagePath = selectedUefiImagePath;
    if (device == null || imagePath == null || !canBootFromRecovery) return;
    await _guard(() async {
      logger.info('${device.serial} を Recovery から UEFI ブートします: '
          '${imagePath.split(RegExp(r'[\\/]')).last}');
      await RecoveryBootChain(_runner).bootFromRecovery(
        serial: device.serial,
        imagePath: imagePath,
        onProgress: (line) => logger.info(line),
      );
    });
    await _afterReboot();
  }

  /// 選択中の fastboot 端末で、選択中のイメージを一時ブートする。
  Future<void> bootSelectedUefi() async {
    final device = selected;
    final imagePath = selectedUefiImagePath;
    if (device == null || imagePath == null || !canBootUefi) return;
    await _guard(() async {
      logger.info(
          '${device.serial} で UEFI を一時ブートします: ${imagePath.split(RegExp(r'[\\/]')).last}');
      await FastbootClient(_runner).boot(
        device.serial,
        imagePath,
        onOutput: (line) => logger.info('fastboot: $line'),
      );
      logger.info('ブートイメージを送信しました。端末側で UEFI が起動します。');
    });
  }

  // ---- Phase 2: バックアップ / 復元 ----

  BackupManifest? loadedManifest;
  String? loadedBackupDirPath;

  /// バックアップ/復元の実行条件: Recovery で GPT（両コピー）読み取り済み。
  bool get canUseBackupOps =>
      selected?.mode == DeviceMode.recovery &&
      primaryTable != null &&
      backupTable != null &&
      totalLbas != null;

  Future<Directory> _backupsRoot() async {
    final dir = Directory(
        '${(await _appDataDir()).path}${Platform.pathSeparator}backups');
    await dir.create(recursive: true);
    return dir;
  }

  String _stamp() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  Future<AdbLbaReader> _readerFor(ToolboxDevice device, AdbClient adb) async {
    final info = await adb.blockInfo(device.serial);
    return AdbLbaReader(adb, device.serial, info);
  }

  Future<String> _productDevice(ToolboxDevice device, AdbClient adb) async {
    try {
      return await adb.getProp(device.serial, 'ro.product.device') ??
          device.product ??
          '';
    } catch (_) {
      return device.product ?? '';
    }
  }

  OperationPlan buildBackupGptPlan() => const OperationPlanner().planBackupGpt(
        serial: selected!.serial,
        primary: primaryTable!,
        backup: backupTable!,
        totalLbas: totalLbas!,
      );

  OperationPlan buildBackupPartitionsPlan(List<String> names) =>
      const OperationPlanner().planBackupPartitions(
        serial: selected!.serial,
        primary: primaryTable!,
        names: names,
      );

  Future<void> executeBackupPlan(OperationPlan plan) async {
    final device = selected;
    if (device == null) return;
    await _guard(() async {
      final adb = AdbClient(_runner);
      final reader = await _readerFor(device, adb);
      final kind = plan.kind == PlanKind.backupGpt ? 'gpt' : 'partitions';
      final outDir = Directory(
          '${(await _backupsRoot()).path}${Platform.pathSeparator}${_stamp()}-$kind');
      logger.info('バックアップを実行します: ${plan.title}');
      final manifest = await const BackupExecutor().execute(
        plan,
        reader: reader,
        outDir: outDir,
        serial: device.serial,
        productDevice: await _productDevice(device, adb),
        currentFingerprint: primaryTable!.fingerprint,
        onProgress: (l) => logger.info(l),
      );
      logger.info(
          'バックアップ完了: ${outDir.path}（${manifest.files.length} ファイル）');
    });
  }

  Future<void> loadBackupManifest(String manifestPath) async {
    await _guard(() async {
      final text = await File(manifestPath).readAsString();
      loadedManifest = BackupManifest.decode(text);
      loadedBackupDirPath = File(manifestPath).parent.path;
      logger.info('バックアップを読み込みました: '
          'シリアル ${loadedManifest!.deviceSerial} / '
          '${loadedManifest!.files.length} ファイル');
    });
  }

  /// 手作業時代のバックアップ（GPT 単一ダンプ＋生イメージ群）を
  /// Toolbox 形式に取り込む。取り込み時点で接続中の端末のバックアップ
  /// として manifest を発行する（元データはこの端末のものという前提）。
  Future<void> importLegacyBackup({
    String? gptDumpPath,
    Map<String, String> partitionPaths = const {},
  }) async {
    final device = selected;
    if (device == null || primaryTable == null || totalLbas == null) return;
    await _guard(() async {
      final outDir = Directory(
          '${(await _backupsRoot()).path}${Platform.pathSeparator}${_stamp()}-legacy-import');
      final manifest = await LegacyImport.importSet(
        gptDump:
            gptDumpPath == null ? null : await File(gptDumpPath).readAsBytes(),
        partitionFiles: {
          for (final e in partitionPaths.entries) e.key: File(e.value),
        },
        outDir: outDir,
        deviceSerial: device.serial,
        productDevice: await _productDevice(device, AdbClient(_runner)),
        sectorSize: primaryTable!.sectorSize,
        totalLbas: totalLbas!,
        sdaPrimary: primaryTable,
      );
      loadedManifest = manifest;
      loadedBackupDirPath = outDir.path;
      logger.info('旧バックアップを取り込みました: ${outDir.path}');
    });
  }

  OperationPlan buildRestoreGptPlan() {
    final dir = loadedBackupDirPath!;
    final sector = primaryTable!.sectorSize;
    final sep = Platform.pathSeparator;
    final primaryBytes =
        File('$dir${sep}gpt_primary.bin').readAsBytesSync();
    final backupBytes = File('$dir${sep}gpt_backup.bin').readAsBytesSync();
    final rp = GptParser.parsePrimary(primaryBytes, sectorSize: sector);
    final rb = GptParser.parseBackup(backupBytes,
        sectorSize: sector, totalLbas: totalLbas!);
    return const OperationPlanner().planRestoreGpt(
      serial: selected!.serial,
      currentPrimary: primaryTable!,
      restorePrimary: rp,
      restoreBackup: rb,
      totalLbas: totalLbas!,
      restorePath: dir,
    );
  }

  Future<void> executeRestoreGptPlan(OperationPlan plan) async {
    final device = selected;
    if (device == null) return;
    await _guard(() async {
      await _executeRestoreGpt(plan, device, (l) => logger.info(l));
      logger.info('GPT 復元が完了しました。再起動して確認してください');
    });
  }

  /// GPT 復元の実処理（ウィザードからも使う）。
  Future<void> _executeRestoreGpt(
    OperationPlan plan,
    ToolboxDevice device,
    void Function(String line) log,
  ) async {
    final adb = AdbClient(_runner);
    final reader = await _readerFor(device, adb);
    final dir = plan.data['restorePath'] as String;
    final sep = Platform.pathSeparator;
    final primaryRegion =
        await File('$dir${sep}gpt_primary.bin').readAsBytes();
    final backupRegion = await File('$dir${sep}gpt_backup.bin').readAsBytes();
    final rp = GptParser.parsePrimary(primaryRegion,
        sectorSize: primaryTable!.sectorSize);
    log('GPT 復元を実行します（書き込み前に現在の GPT を自動保存します）');
    await RestoreExecutor(adb).executeRestoreGpt(
      plan,
      serial: device.serial,
      reader: reader,
      primaryRegion: primaryRegion,
      backupRegion: backupRegion,
      restorePrimary: rp,
      workDir: Directory(
          '${(await _backupsRoot()).path}${Platform.pathSeparator}work'),
      autoBackup: () async {
        final pre = const OperationPlanner().planBackupGpt(
          serial: device.serial,
          primary: primaryTable!,
          backup: backupTable!,
          totalLbas: totalLbas!,
        );
        await const BackupExecutor().execute(
          pre,
          reader: reader,
          outDir: Directory(
              '${(await _backupsRoot()).path}${Platform.pathSeparator}${_stamp()}-pre-restore'),
          serial: device.serial,
          productDevice: await _productDevice(device, adb),
          currentFingerprint: primaryTable!.fingerprint,
          onProgress: log,
        );
      },
      currentFingerprint: primaryTable!.fingerprint,
      onProgress: log,
    );
    primaryTable = null;
    backupTable = null;
    totalLbas = null;
    gptConsistent = null;
    layout = null;
  }

  // ---- ウィザード: Android（LineageOS）に戻す ----

  ReturnStep? wizardStep;
  String wizardMessage = '';

  Future<void> runReturnToAndroid(String lineageZipPath) async {
    final device = selected;
    if (device == null || !canUseBackupOps || loadedBackupDirPath == null) {
      return;
    }
    await _guard(() async {
      final plan = buildRestoreGptPlan();
      final sep = Platform.pathSeparator;
      final rp = GptParser.parsePrimary(
        await File('${loadedBackupDirPath!}${sep}gpt_primary.bin')
            .readAsBytes(),
        sectorSize: primaryTable!.sectorSize,
      );
      final currentPrimary = primaryTable!;
      final wizard = ReturnToAndroidWizard(
        adb: AdbClient(_runner),
        probe: () => DeviceProbe(_runner).probe(),
        restoreGpt: (onProgress) =>
            _executeRestoreGpt(plan, device, onProgress),
      );
      await wizard.run(
        serial: device.serial,
        currentPrimary: currentPrimary,
        restorePrimary: rp,
        lineageZipPath: lineageZipPath,
        onStep: (step, message) {
          wizardStep = step;
          wizardMessage = message;
          logger.info('[ウィザード] $message');
          notifyListeners();
        },
      );
    });
  }

  OperationPlan buildRestorePartitionPlan(BackupFileEntry entry) =>
      const OperationPlanner().planRestorePartition(
        serial: selected!.serial,
        // adb devices -l の product: は ro.product.device と同じ出所。
        productDevice: selected!.product ?? '',
        currentPrimary: primaryTable!,
        manifest: loadedManifest!,
        entry: entry,
      );

  Future<void> executeRestorePartitionPlan(
      OperationPlan plan, BackupFileEntry entry) async {
    final device = selected;
    if (device == null) return;
    await _guard(() async {
      final adb = AdbClient(_runner);
      final reader = await _readerFor(device, adb);
      final file = File(
          '${loadedBackupDirPath!}${Platform.pathSeparator}${entry.fileName}');
      logger.info('${entry.partitionName} の書き戻しを実行します');
      await RestoreExecutor(adb).executeRestorePartition(
        plan,
        serial: device.serial,
        reader: reader,
        localFile: file,
        currentFingerprint: primaryTable!.fingerprint,
        onProgress: (l) => logger.info(l),
      );
      logger.info('書き戻しが完了しました');
    });
  }

  // ---- ウィザード: Windows インストール ----

  WinInstallStep? winWizardStep;
  String winWizardMessage = '';

  Future<void> runWindowsInstall({
    required String winDir,
    required String espDir,
    required String wimPath,
    int imageIndex = 1,
    String? driverPackDir,
    String? unattendPath,
  }) async {
    await _guard(() async {
      final wizard = WindowsInstallWizard(
        runner: _runner,
        winDir: winDir,
        espDir: espDir,
        wimPath: wimPath,
        imageIndex: imageIndex,
        driverPackDir: driverPackDir,
        unattendPath: unattendPath,
      );
      await wizard.run(
        onStep: (step, message) {
          winWizardStep = step;
          winWizardMessage = message;
          logger.info('[Winインストール] $message');
          notifyListeners();
        },
      );
    });
  }

  Future<void> _guard(Future<void> Function() body) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      error = e.toString();
      logger.error(e.toString());
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
