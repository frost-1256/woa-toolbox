import 'package:flutter/material.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'app_state.dart';
import 'uefi_page.dart';

void main() {
  runApp(WoaToolboxApp(state: AppState()));
}

class WoaToolboxApp extends StatelessWidget {
  const WoaToolboxApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: 'WoA Toolbox',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: state.themeMode,
        home: HomePage(state: state),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    widget.state.loadUefiLibrary();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('WoA Toolbox'),
            actions: [
              IconButton(
                icon: Icon(
                  switch (state.themeMode) {
                    ThemeMode.dark => Icons.light_mode,
                    ThemeMode.light => Icons.dark_mode,
                    _ => Icons.brightness_auto,
                  },
                ),
                tooltip: 'テーマ切替（システム/ダーク/ライト）',
                onPressed: () => state.setThemeMode(switch (state.themeMode) {
                  ThemeMode.system => ThemeMode.dark,
                  ThemeMode.dark => ThemeMode.light,
                  _ => ThemeMode.system,
                }),
              ),
              if (state.busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: Text('ダッシュボード'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.view_list_outlined),
                    selectedIcon: Icon(Icons.view_list),
                    label: Text('パーティション'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.rocket_launch_outlined),
                    selectedIcon: Icon(Icons.rocket_launch),
                    label: Text('UEFI'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.terminal_outlined),
                    selectedIcon: Icon(Icons.terminal),
                    label: Text('ログ'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: switch (_index) {
                  0 => DashboardPage(state: state),
                  1 => PartitionsPage(state: state),
                  2 => UefiPage(state: state),
                  _ => LogsPage(state: state),
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

String _modeLabel(DeviceMode mode) => switch (mode) {
      DeviceMode.android => 'Android',
      DeviceMode.recovery => 'Recovery',
      DeviceMode.sideload => 'Sideload',
      DeviceMode.fastboot => 'Fastboot',
      DeviceMode.unauthorized => '未認証',
      DeviceMode.offline => 'オフライン',
      DeviceMode.unknown => '不明',
    };

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: state.busy ? null : state.refreshDevices,
                icon: const Icon(Icons.search),
                label: const Text('端末を検出'),
              ),
              const SizedBox(width: 12),
              Text(
                'adb / fastboot は PATH から使います',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(width: 16),
              const Text('自動検出'),
              Switch(
                value: state.autoDetect,
                onChanged: state.setAutoDetect,
              ),
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(state.error!),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: state.devices.isEmpty
                ? const Center(child: Text('端末はまだ検出されていません'))
                : ListView(
                    children: [
                      for (final device in state.devices)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.smartphone),
                            title: Text(device.serial),
                            subtitle: Text(device.product ?? ''),
                            trailing: Chip(label: Text(_modeLabel(device.mode))),
                            selected: state.selected?.serial == device.serial,
                            onTap: () => state.select(device),
                          ),
                        ),
                    ],
                  ),
          ),
          if (state.selected != null) ...[
            const Divider(),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed:
                      (state.busy || !state.canReadGpt) ? null : state.readGpt,
                  icon: const Icon(Icons.storage),
                  label: const Text('GPT を読み取る'),
                ),
                const SizedBox(width: 12),
                if (!state.canReadGpt)
                  const Text('GPT 読み取りは Recovery / Android モードで可能です'),
                if (state.canUseMassStorage) ...[
                  const SizedBox(width: 24),
                  FilledButton.tonalIcon(
                    onPressed: (state.busy ||
                            state.massStorage == MassStorageState.on)
                        ? null
                        : state.enableMassStorage,
                    icon: const Icon(Icons.usb),
                    label: const Text('Mass Storage を有効化'),
                  ),
                  const SizedBox(width: 8),
                  if (state.massStorage != null)
                    Chip(
                      label: Text(switch (state.massStorage!) {
                        MassStorageState.on => 'Mass Storage: ON',
                        MassStorageState.off => 'Mass Storage: OFF',
                        MassStorageState.unknown => 'Mass Storage: 不明',
                      }),
                    ),
                ],
                if (state.layout != null) ...[
                  Chip(
                    label: Text(switch (state.layout!) {
                      PartitionLayout.woa => 'レイアウト: WoA',
                      PartitionLayout.android => 'レイアウト: Android',
                      PartitionLayout.unknown => 'レイアウト: 不明',
                    }),
                  ),
                  const SizedBox(width: 8),
                  if (state.gptConsistent != null)
                    Chip(
                      label:
                          Text(state.gptConsistent! ? 'GPT 整合 OK' : 'GPT 不整合'),
                    ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: state.busy ? null : state.rebootToBootloader,
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('ブートローダーで再起動'),
                ),
                if (state.selected!.mode != DeviceMode.recovery)
                  OutlinedButton.icon(
                    onPressed: state.busy ? null : state.rebootToRecovery,
                    icon: const Icon(Icons.healing),
                    label: const Text('Recovery で再起動'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class PartitionsPage extends StatelessWidget {
  const PartitionsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final table = state.primaryTable;
    if (table == null) {
      return const Center(child: Text('ダッシュボードで端末を選び、GPT を読み取ってください'));
    }
    String gib(GptPartition p) =>
        (p.sizeBytes(table.sectorSize) / 1073741824).toStringAsFixed(3);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: DataTable(
        columns: const [
          DataColumn(label: Text('#')),
          DataColumn(label: Text('名前')),
          DataColumn(label: Text('開始 LBA'), numeric: true),
          DataColumn(label: Text('終了 LBA'), numeric: true),
          DataColumn(label: Text('サイズ (GiB)'), numeric: true),
        ],
        rows: [
          for (final p in table.partitions)
            DataRow(cells: [
              DataCell(Text('${p.index}')),
              DataCell(Text(p.name)),
              DataCell(Text('${p.firstLba}')),
              DataCell(Text('${p.lastLba}')),
              DataCell(Text(gib(p))),
            ]),
        ],
      ),
    );
  }
}

class LogsPage extends StatelessWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final records = state.logger.records;
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: records.length,
      itemBuilder: (context, i) => Text(
        records[i].toString(),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}
