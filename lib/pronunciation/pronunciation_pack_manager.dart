import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'pronunciation_pack_store.dart';
import 'pronunciation_selection_transfer.dart';
import 'pronunciation_store.dart';

class PronunciationPackManager extends StatefulWidget {
  const PronunciationPackManager({super.key});
  @override
  State<PronunciationPackManager> createState() =>
      _PronunciationPackManagerState();
}

class _PronunciationPackManagerState extends State<PronunciationPackManager> {
  final _store = PronunciationPackStore();
  final _selections = PronunciationSelectionStore();
  late final Future<void> _selectionLoad;
  var _busy = false;
  var _packs = <InstalledPronunciationPack>[];

  @override
  void initState() {
    super.initState();
    _reload();
    _selectionLoad = _selections.load();
  }

  Future<void> _exportSelections() async {
    try {
      await _selectionLoad;
      final saved = await savePronunciationSelections(_selections);
      if (!mounted || !saved) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('발음 선택 파일을 저장했어요')));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('발음 선택 파일을 저장하지 못했어요')));
      }
    }
  }

  Future<void> _importSelections() async {
    try {
      await _selectionLoad;
      final count = await importPronunciationSelections(_selections);
      if (!mounted || count == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('발음 선택 $count개를 가져왔어요')));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('발음 선택 파일 형식을 확인해 주세요')));
      }
    }
  }

  Future<void> _reload() async {
    if (kIsWeb) return;
    final packs = await _store.list();
    if (mounted) setState(() => _packs = packs);
  }

  Future<void> _install() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'vfpitch'],
        withData: true);
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    setState(() => _busy = true);
    try {
      await _store.install(bytes);
      await _reload();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('음성팩을 설치했어요')));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('음성팩 형식을 확인해 주세요')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('일본어 발음팩')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('고저 액센트 음성과 표시를 위한 오프라인 음성팩입니다.'),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: _busy || kIsWeb ? null : _install,
              icon: const Icon(Icons.upload_file),
              label: Text(_busy ? '설치 중…' : '음성팩 가져오기')),
          const SizedBox(height: 8),
          const Text('두 휴대폰에서 같은 발음 선택을 쓰려면 선택 파일도 옮겨 주세요.',
              style: TextStyle(color: Color(0xFF6E6E73), fontSize: 12)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy || kIsWeb ? null : _exportSelections,
                icon: const Icon(Icons.ios_share_outlined, size: 18),
                label: const Text('선택 내보내기'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy || kIsWeb ? null : _importSelections,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('선택 가져오기'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          for (final pack in _packs)
            Card(
                child: ListTile(
              leading: const Icon(Icons.record_voice_over_outlined),
              title: Text('단어 ${pack.manifest.entries.length}개'),
              subtitle: Text('팩 ${pack.manifest.packId.substring(0, 8)}'),
            )),
          if (!_busy && _packs.isEmpty)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('설치된 음성팩이 없습니다.'))),
        ]),
      );
}
