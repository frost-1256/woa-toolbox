import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';

class UefiPage extends StatefulWidget {
  const UefiPage({super.key, required this.state});

  final AppState state;

  @override
  State<UefiPage> createState() => _UefiPageState();
}

class _UefiPageState extends State<UefiPage> {
  late final TextEditingController _tokenController;

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(text: widget.state.githubToken);
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  String _size(int bytes) =>
      '${(bytes / 1048576).toStringAsFixed(2)} MiB';

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (_tokenController.text.isEmpty && state.githubToken.isNotEmpty) {
      _tokenController.text = state.githubToken;
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('GitHub Actions から取得',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          'frost-1256/Mu-Silicium の spacewar ワークフローで成功した最新 run の '
          'uefi-spacewar 成果物を取得します。成果物のダウンロードには GitHub の '
          'トークンが必要です（fine-grained PAT で対象リポジトリの Actions 読み取り権限）。'
          'トークンはこの端末のアプリデータ内に保存されます。',
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _tokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'GitHub トークン',
                  border: OutlineInputBorder(),
                ),
                onChanged: state.setGithubToken,
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: state.busy ? null : state.downloadLatestUefi,
              icon: const Icon(Icons.download),
              label: const Text('最新の UEFI を取得'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('イメージライブラリ',
                style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: state.busy
                  ? null
                  : () async {
                      final result = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['img'],
                      );
                      final path = result?.files.single.path;
                      if (path != null) await state.addUefiImage(path);
                    },
              icon: const Icon(Icons.add),
              label: const Text('ファイルを追加'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (state.uefiImages.isEmpty)
          const Text('イメージがまだありません。Actions から取得するか、ファイルを追加してください。')
        else
          for (final image in state.uefiImages)
            Card(
              child: ListTile(
                leading: Icon(
                  state.selectedUefiImagePath == image.path
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(image.name),
                subtitle: Text(
                    '${_size(image.sizeBytes)} / ${image.modified.toLocal()}'),
                selected: state.selectedUefiImagePath == image.path,
                onTap: () => state.selectUefiImage(image.path),
              ),
            ),
        const SizedBox(height: 24),
        Text('fastboot boot（ 一時ブート）',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          state.selected == null
              ? 'ダッシュボードで fastboot モードの端末を選んでください。'
              : '対象端末: ${state.selected!.serial}（モード: ${state.selected!.mode.name}）',
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed:
                  (state.busy || !state.canBootUefi) ? null : state.bootSelectedUefi,
              icon: const Icon(Icons.play_arrow),
              label: const Text('fastboot boot 実行'),
            ),
            const SizedBox(width: 12),
            if (!state.canBootUefi)
              const Expanded(
                child: Text('fastboot モードの端末と、ライブラリで選択したイメージが必要です。'
                    'フラッシュはしません（一時ブートのみ）。'),
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
      ],
    );
  }
}
