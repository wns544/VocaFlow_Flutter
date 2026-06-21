import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auto_backup.dart';
import 'cloud_change_tracker.dart';
import 'cloud_backup.dart';
import 'csv_parser.dart';
import 'excel_exporter.dart';
import 'excel_parser.dart';
import 'firebase_options.dart';
import 'local_word_search.dart';
import 'models.dart';
import 'store.dart';

const ink = Color(0xFF1C1C1E);
const sea = Color(0xFF34C759);
const mist = Color(0xFFF2F2F7);
const coral = Color(0xFFFF3B30);

bool shuffleNewStudyQueues = true;

List<T> shuffledStudyQueue<T>(Iterable<T> items, {Random? random}) =>
    List<T>.of(items)..shuffle(random);

String? japaneseFontFamily(VocaStore store) => switch (store.japaneseFont) {
      'notoSerifJP' => 'NotoSerifJP',
      'sourceHanSerifJP' => 'SourceHanSerifJP',
      _ => null,
    };

bool isHanCharacter(String text) =>
    RegExp(r'^[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]$').hasMatch(text);

bool isBookCompleted(VocaStore store, WordBook book) {
  final count = store.sessionCount(book);
  return count > 0 && store.completedCount(book) == count;
}

var firebaseReady = false;
Future<void>? _googleSignInInitFuture;
const _googleServerClientId =
    '551902347979-55n8b79u8nrs647b8lgo5vl2lsiq0iet.apps.googleusercontent.com';

Future<void> ensureGoogleSignInInitialized() {
  return _googleSignInInitFuture ??= GoogleSignIn.instance.initialize(
    serverClientId: _googleServerClientId,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;
  } catch (_) {
    firebaseReady = false;
  }
  runApp(const VocaFlowApp());
}

class VocaFlowApp extends StatefulWidget {
  const VocaFlowApp({super.key});

  @override
  State<VocaFlowApp> createState() => _VocaFlowAppState();
}

class _VocaFlowAppState extends State<VocaFlowApp> {
  VocaStore? store;
  AutoBackupCoordinator? autoBackup;

  @override
  void initState() {
    super.initState();
    VocaStore.load().then((value) {
      if (!mounted) return;
      final coordinator = firebaseReady
          ? AutoBackupCoordinator(
              store: value,
              onChanged: () {
                if (mounted) setState(() {});
              },
            )
          : null;
      coordinator?.start();
      setState(() {
        store = value;
        autoBackup = coordinator;
      });
    });
  }

  @override
  void dispose() {
    autoBackup?.dispose();
    super.dispose();
  }

  ThemeData get theme {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: sea,
        primary: sea,
        secondary: coral,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: mist,
      fontFamily: 'Nunito',
      cardTheme: const CardThemeData(
        elevation: 0,
        color: Colors.white,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: Color(0x14000000)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
    final japaneseFamily = store == null ? null : japaneseFontFamily(store!);
    final fallback = japaneseFamily == null ? null : [japaneseFamily];
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamilyFallback: fallback),
      primaryTextTheme:
          base.primaryTextTheme.apply(fontFamilyFallback: fallback),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'VocaFlow',
        theme: theme,
        home: store == null
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : MainShell(
                store: store!,
                autoBackup: autoBackup,
                onChanged: () => setState(() {}),
              ),
      );
}

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.store,
    required this.onChanged,
    this.autoBackup,
  });
  final VocaStore store;
  final VoidCallback onChanged;
  final AutoBackupCoordinator? autoBackup;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  var index = 0;
  var restoredStudy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => restoreStudy());
  }

  Future<void> restoreStudy() async {
    if (restoredStudy || !mounted) return;
    restoredStudy = true;
    final active = widget.store.activeStudy;
    if (active == null) return;
    final words = widget.store.resolveActiveWords(active);
    if (words.length != active.queueIds.length) {
      await widget.store.clearActiveStudy();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardStudyPage(
        store: widget.store,
        resume: active,
      ),
    ));
    if (mounted) refresh();
  }

  void refresh() {
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(store: widget.store, refresh: refresh),
      BooksPage(store: widget.store, refresh: refresh),
      SettingsPage(
          store: widget.store, refresh: refresh, autoBackup: widget.autoBackup),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: index, children: pages)),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: index,
        onTap: (value) => setState(() => index = value),
        backgroundColor: Colors.white,
        elevation: 0,
        selectedItemColor: sea,
        unselectedItemColor: const Color(0xFF8E8E93),
        selectedFontSize: 12,
        unselectedFontSize: 12,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.local_fire_department_outlined, size: 21),
              activeIcon: Icon(Icons.local_fire_department, size: 21),
              label: '학습'),
          BottomNavigationBarItem(
              icon: Icon(Icons.menu_book_outlined, size: 21),
              activeIcon: Icon(Icons.menu_book, size: 21),
              label: '단어장'),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings_outlined, size: 21),
              activeIcon: Icon(Icons.settings, size: 21),
              label: '설정'),
        ],
      ),
    );
  }
}

class LegacyHomePage extends StatefulWidget {
  const LegacyHomePage({super.key, required this.store, required this.refresh});
  final VocaStore store;
  final VoidCallback refresh;

  @override
  State<LegacyHomePage> createState() => _HomePageState();
}

class _HomePageState extends State<LegacyHomePage> {
  late String selectedBookId = widget.store.quickBook.id;
  final selectedSessions = <int>{};

  WordBook get book => widget.store.books.firstWhere(
        (item) => item.id == selectedBookId,
        orElse: () => widget.store.books.first,
      );

  @override
  Widget build(BuildContext context) {
    final sessions = book.sessions(widget.store.sessionSize);
    final memorized =
        book.words.where((word) => word.state == StudyState.memorized).length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('VOCAFLOW',
                        style: TextStyle(
                            color: sea,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2)),
                    SizedBox(height: 3),
                    Text('오늘도 단어 정복',
                        style: TextStyle(
                            color: ink,
                            fontSize: 24,
                            fontWeight: FontWeight.w800)),
                  ])),
              _CircleStat(value: '${widget.store.streak}', label: '일 연속'),
            ]),
            const SizedBox(height: 14),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.store.books.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, index) {
                  final item = widget.store.books[index];
                  final selected = item.id == selectedBookId;
                  return ChoiceChip(
                    selected: selected,
                    label: Text(item.name),
                    onSelected: (_) async {
                      await widget.store.selectQuickBook(item.id);
                      setState(() {
                        selectedBookId = item.id;
                        selectedSessions.clear();
                      });
                      widget.refresh();
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Card(
                child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(book.name,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                          '${book.words.isEmpty ? 0 : (memorized / book.words.length * 100).round()}%',
                          style: const TextStyle(
                              color: sea, fontWeight: FontWeight.w800)),
                    ]),
                const SizedBox(height: 9),
                LinearProgressIndicator(
                    value:
                        book.words.isEmpty ? 0 : memorized / book.words.length,
                    borderRadius: BorderRadius.circular(99)),
                const SizedBox(height: 5),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text('$memorized/${book.words.length} 외움',
                        style: const TextStyle(
                            color: Colors.black45, fontSize: 12))),
              ]),
            )),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('세션 선택',
                style: TextStyle(
                    color: Colors.black54, fontWeight: FontWeight.w700)),
            if (selectedSessions.isNotEmpty)
              Text('${selectedSessions.length}개 선택됨',
                  style:
                      const TextStyle(color: sea, fontWeight: FontWeight.w700)),
          ]),
        ),
        Expanded(
          child: sessions.isEmpty
              ? const Center(child: Text('단어장에서 CSV를 가져와 주세요.'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  itemCount: sessions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, index) {
                    final session = sessions[index];
                    final selected = selectedSessions.contains(index);
                    return Card(
                      color: selected ? sea : Colors.white,
                      child: ListTile(
                        onTap: () => setState(() => selected
                            ? selectedSessions.remove(index)
                            : selectedSessions.add(index)),
                        leading: CircleAvatar(
                          backgroundColor: selected
                              ? Colors.white24
                              : const Color(0xFFE5E5EA),
                          foregroundColor: selected
                              ? Colors.white
                              : (session.isCompleted ? sea : Colors.black45),
                          child: Icon(session.isCompleted
                              ? Icons.check
                              : Icons.school_outlined),
                        ),
                        title: Text(session.label,
                            style: TextStyle(
                                color: selected ? Colors.white : ink,
                                fontWeight: FontWeight.w700)),
                        subtitle: Text(
                            '${session.memorizedCount}/${session.words.length} 단어',
                            style: TextStyle(
                                color: selected
                                    ? Colors.white70
                                    : Colors.black45)),
                        trailing: selected
                            ? const Icon(Icons.check_circle,
                                color: Colors.white)
                            : null,
                      ),
                    );
                  },
                ),
        ),
        if (selectedSessions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(children: [
              Expanded(
                  child: OutlinedButton.icon(
                      onPressed: () => _openStudy(context, true),
                      icon: const Icon(Icons.keyboard_alt_outlined),
                      label: const Text('퀴즈'))),
              const SizedBox(width: 10),
              Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                      onPressed: () => _openStudy(context, false),
                      icon: const Icon(Icons.style),
                      label: Text(selectedSessions.length > 1
                          ? '${selectedSessions.length}개 세션 합쳐서 학습'
                          : '학습 시작하기'))),
            ]),
          ),
      ],
    );
  }

  Future<void> _openStudy(BuildContext context, bool quiz) async {
    final indexes = selectedSessions.toList()..sort();
    final sessions = book.sessions(widget.store.sessionSize);
    final words = indexes.expand((index) => sessions[index].words).toList();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => quiz
          ? QuizPage(
              store: widget.store,
              words: words,
              bookId: book.id,
              sessionIndexes: indexes)
          : CardStudyPage(
              store: widget.store,
              words: words,
              bookId: book.id,
              sessionIndexes: indexes),
    ));
    if (!mounted) return;
    setState(selectedSessions.clear);
    widget.refresh();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store, required this.refresh});

  final VocaStore store;
  final VoidCallback refresh;

  @override
  State<HomePage> createState() => _ReferenceHomePageState();
}

class _ReferenceHomePageState extends State<HomePage> {
  late String selectedBookId = widget.store.quickBook.id;
  final selectedSessions = <int>{};
  final expandedFavoriteIds = <String>{};

  WordBook get book => widget.store.books.firstWhere(
        (item) => item.id == selectedBookId,
        orElse: () => widget.store.books.first,
      );

  @override
  Widget build(BuildContext context) {
    final sessions = book.sessions(widget.store.sessionSize);
    final memorized =
        book.words.where((word) => word.state == StudyState.memorized).length;
    final reviewWords =
        book.words.where((word) => word.state == StudyState.review).toList();
    final favoriteBooks =
        widget.store.books.where((item) => item.isFavorite).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
              child: Text('VOCAFLOW',
                  style: TextStyle(
                      color: sea,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.8))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                border: Border.all(color: const Color(0xFFFED7AA)),
                borderRadius: BorderRadius.circular(99)),
            child: Row(children: [
              const Icon(Icons.local_fire_department,
                  color: Color(0xFFFB923C), size: 14),
              const SizedBox(width: 3),
              Text('${widget.store.streak}일',
                  style: const TextStyle(
                      color: Color(0xFFF97316),
                      fontSize: 12,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 16, 10),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('현재 학습 단어장',
                            style: TextStyle(
                                color: Color(0xFF8E8E93),
                                fontSize: 10,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 1),
                        Text(book.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: ink,
                                fontSize: 17,
                                fontWeight: FontWeight.w800)),
                      ]),
                ),
                const SizedBox(width: 12),
                Text(
                    '${book.words.isEmpty ? 0 : (memorized / book.words.length * 100).round()}%',
                    style: const TextStyle(
                        color: sea, fontSize: 12, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 7),
              LinearProgressIndicator(
                  value: book.words.isEmpty ? 0 : memorized / book.words.length,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(99),
                  backgroundColor: const Color(0xFFE5E5EA)),
              const SizedBox(height: 5),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('$memorized/${book.words.length} 외움',
                      style: const TextStyle(
                          color: Color(0xFF8E8E93), fontSize: 11))),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: _QuickAction(
            icon: Icons.history,
            iconColor: const Color(0xFFFB923C),
            iconBackground: const Color(0xFFFFF7ED),
            title: '복습하기',
            subtitle:
                reviewWords.isEmpty ? '기록 없음' : '${reviewWords.length}개 단어',
            onTap: reviewWords.isEmpty
                ? null
                : () => _openReview(context, reviewWords),
          )),
          const SizedBox(width: 8),
          Expanded(
              child: _QuickAction(
            icon: Icons.play_circle_outline,
            iconColor: sea,
            iconBackground: const Color(0x1A34C759),
            title: '학습하기',
            subtitle: '처음부터',
            onTap:
                sessions.isEmpty ? null : () => _startNext(context, sessions),
          )),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 42,
          child: OutlinedButton.icon(
            key: const ValueKey('multi-session-study'),
            onPressed:
                sessions.isEmpty ? null : () => _chooseSessions(sessions),
            icon: const Icon(Icons.playlist_add_check, size: 19),
            label: const Text('여러 세션 골라 학습'),
            style: OutlinedButton.styleFrom(
              foregroundColor: ink,
              side: const BorderSide(color: Color(0xFFDADCE0)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text('즐겨찾기 단어장',
            style: TextStyle(
                color: Color(0xFF8E8E93),
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Expanded(
          child: favoriteBooks.isEmpty
              ? const Center(
                  child: Text(
                    '즐겨찾기한 단어장이 없습니다.\n단어장 탭에서 별표를 눌러 추가해 주세요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF8E8E93), height: 1.5),
                  ),
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: favoriteBooks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 7),
                  itemBuilder: (_, index) {
                    final favorite = favoriteBooks[index];
                    final completedCount =
                        widget.store.completedCount(favorite);
                    final sessionCount = widget.store.sessionCount(favorite);
                    final expanded = expandedFavoriteIds.contains(favorite.id);
                    final favoriteSessions =
                        favorite.sessions(widget.store.sessionSize);
                    return Card(
                      key: ValueKey('favorite-book-card-${favorite.id}'),
                      color: isBookCompleted(widget.store, favorite)
                          ? const Color(0xFFEDEDED)
                          : Colors.white,
                      child: Column(children: [
                        SizedBox(
                          height: 68,
                          child: ListTile(
                            dense: true,
                            onTap: () => setState(() => expanded
                                ? expandedFavoriteIds.remove(favorite.id)
                                : expandedFavoriteIds.add(favorite.id)),
                            leading: CircleAvatar(
                              radius: 16,
                              backgroundColor: const Color(0x1A34C759),
                              foregroundColor: sea,
                              child: const Icon(Icons.menu_book_outlined,
                                  size: 16),
                            ),
                            title: Text(favorite.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: ink,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800)),
                            subtitle: Text(
                                '$completedCount/$sessionCount 세션 완료 · ${favorite.words.length}단어',
                                style: const TextStyle(
                                    color: Color(0xFF8E8E93), fontSize: 12)),
                            trailing: IconButton(
                              key: ValueKey('favorite-sessions-${favorite.id}'),
                              tooltip: expanded ? '세션 접기' : '세션 펼치기',
                              onPressed: () => setState(() => expanded
                                  ? expandedFavoriteIds.remove(favorite.id)
                                  : expandedFavoriteIds.add(favorite.id)),
                              icon: AnimatedRotation(
                                turns: expanded ? .5 : 0,
                                duration: const Duration(milliseconds: 180),
                                child: const Icon(Icons.keyboard_arrow_down,
                                    color: Color(0xFF8E8E93), size: 20),
                              ),
                            ),
                          ),
                        ),
                        if (expanded) ...[
                          const Divider(height: 1),
                          ...favoriteSessions.map((session) => Material(
                                color: widget.store.isSessionCompleted(
                                        favorite.id, session.index)
                                    ? const Color(0xFFEDEDED)
                                    : Colors.transparent,
                                child: ListTile(
                                  key: ValueKey(
                                      'favorite-${favorite.id}-session-${session.index}'),
                                  dense: true,
                                  contentPadding: const EdgeInsets.only(
                                      left: 58, right: 14),
                                  title: Text(session.label,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700)),
                                  subtitle: Text(
                                      '${session.memorizedCount}/${session.words.length} 단어'),
                                  trailing: const Icon(Icons.play_arrow_rounded,
                                      color: sea, size: 19),
                                  onTap: () =>
                                      _openFavoriteSession(favorite, session),
                                ),
                              )),
                        ],
                      ]),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Future<void> _openFavoriteSession(
      WordBook favorite, StudySession session) async {
    await widget.store.selectQuickBook(favorite.id);
    if (!mounted) return;
    setState(() => selectedBookId = favorite.id);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardStudyPage(
        store: widget.store,
        words: session.words,
        bookId: favorite.id,
        sessionIndexes: [session.index],
      ),
    ));
    if (!mounted) return;
    setState(() {});
    widget.refresh();
  }

  Future<void> _startNext(
      BuildContext context, List<StudySession> sessions) async {
    final next = sessions.firstWhere((session) => !session.isCompleted,
        orElse: () => sessions.first);
    selectedSessions
      ..clear()
      ..add(next.index);
    await _openSelected(context);
  }

  Future<void> _chooseSessions(List<StudySession> sessions) async {
    final chosen = <int>{};
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final wordCount = sessions
              .where((session) => chosen.contains(session.index))
              .fold(0, (total, session) => total + session.words.length);
          return FractionallySizedBox(
            heightFactor: .76,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('여러 세션 골라 학습',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(book.name,
                      style: const TextStyle(
                          color: Color(0xFF8E8E93), fontSize: 12)),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.separated(
                      itemCount: sessions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final session = sessions[index];
                        final completed = widget.store
                            .isSessionCompleted(book.id, session.index);
                        return Material(
                          color: completed
                              ? const Color(0xFFEDEDED)
                              : Colors.transparent,
                          child: CheckboxListTile(
                            key: ValueKey('multi-session-${session.index}'),
                            value: chosen.contains(session.index),
                            onChanged: (selected) => setModalState(() {
                              if (selected == true) {
                                chosen.add(session.index);
                              } else {
                                chosen.remove(session.index);
                              }
                            }),
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(session.label,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text(
                                '${session.words.length}개 단어${completed ? ' · 학습 완료' : ''}'),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      key: const ValueKey('start-multi-session-study'),
                      onPressed: chosen.isEmpty
                          ? null
                          : () =>
                              Navigator.pop(context, chosen.toList()..sort()),
                      icon: const Icon(Icons.style, size: 19),
                      label: Text(chosen.isEmpty
                          ? '세션을 선택하세요'
                          : '${chosen.length}개 세션 · $wordCount개 단어 학습'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    selectedSessions
      ..clear()
      ..addAll(result);
    await _openSelected(context);
  }

  Future<void> _openSelected(BuildContext context) async {
    final indexes = selectedSessions.toList()..sort();
    final sessions = book.sessions(widget.store.sessionSize);
    final words = indexes.expand((index) => sessions[index].words).toList();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardStudyPage(
          store: widget.store,
          words: words,
          bookId: book.id,
          sessionIndexes: indexes),
    ));
    if (!mounted) return;
    setState(selectedSessions.clear);
    widget.refresh();
  }

  Future<void> _openReview(BuildContext context, List<Word> words) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardStudyPage(store: widget.store, words: words),
    ));
    if (!mounted) return;
    setState(() {});
    widget.refresh();
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? .4 : 1,
        child: Card(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(children: [
                Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        color: iconBackground,
                        borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, color: iconColor, size: 19)),
                const SizedBox(width: 11),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF8E8E93), fontSize: 11)),
                    ])),
              ]),
            ),
          ),
        ),
      );
}

class CardStudyPage extends StatefulWidget {
  const CardStudyPage(
      {super.key,
      required this.store,
      this.words,
      this.bookId,
      this.sessionIndexes = const [],
      this.resume});
  final VocaStore store;
  final List<Word>? words;
  final String? bookId;
  final List<int> sessionIndexes;
  final ActiveStudy? resume;

  @override
  State<CardStudyPage> createState() => _CardStudyPageState();
}

class _CardStudyPageState extends State<CardStudyPage>
    with WidgetsBindingObserver {
  late final List<Word> queue;
  late final int total;
  final reviewed = <String>{};
  var memorized = 0;
  var revealed = false;
  var dragY = 0.0;
  var dragging = false;
  var dismissing = false;
  var exiting = false;
  Word? lastWord;
  StudyState? lastState;
  final undoHistory = <StudyDecision>[];

  bool get horizontalSwipe => widget.store.horizontalSwipe;
  String? get activeBookId => widget.resume?.bookId ?? widget.bookId;
  List<int> get activeSessionIndexes =>
      widget.resume?.sessionIndexes ?? widget.sessionIndexes;

  StudyState stateForDirection(bool positive) {
    var memorized = horizontalSwipe ? positive : !positive;
    if (widget.store.reverseSwipe) memorized = !memorized;
    return memorized ? StudyState.memorized : StudyState.review;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final resume = widget.resume;
    if (resume == null) {
      final words = widget.words ?? widget.store.nextWords();
      queue = shuffleNewStudyQueues
          ? shuffledStudyQueue(words)
          : List<Word>.of(words);
      total = queue.length;
    } else {
      queue = widget.store.resolveActiveWords(resume);
      total = resume.total;
      memorized = resume.memorized;
      reviewed.addAll(resume.reviewed);
      revealed = resume.revealed;
      lastState = resume.lastState;
      undoHistory.addAll(resume.undoHistory);
      if (undoHistory.isEmpty &&
          resume.lastWordId != null &&
          resume.lastState != null) {
        undoHistory.add(StudyDecision(
          wordId: resume.lastWordId!,
          previousState: StudyState.fresh,
          decision: resume.lastState!,
        ));
      }
      if (resume.lastWordId != null) {
        lastWord = widget.store.books
            .expand((book) => book.words)
            .where((word) => word.id == resume.lastWordId)
            .firstOrNull;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => persistStudy());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      persistStudy();
    }
  }

  Future<void> persistStudy() async {
    if (queue.isEmpty || exiting) return;
    await widget.store.saveActiveStudy(ActiveStudy(
      queueIds: queue.map((word) => word.id).toList(),
      total: total,
      memorized: memorized,
      reviewed: reviewed.toList(),
      revealed: revealed,
      bookId: activeBookId,
      sessionIndexes: activeSessionIndexes,
      lastWordId: lastWord?.id,
      lastState: lastState,
      undoHistory: undoHistory,
    ));
  }

  Future<void> exitStudy() async {
    if (exiting) return;
    await widget.store.clearActiveStudy();
    if (!mounted) return;
    setState(() => exiting = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> decide(StudyState state) async {
    if (queue.isEmpty) return;
    final word = queue.removeAt(0);
    final previousState = word.state;
    lastWord = word;
    lastState = state;
    undoHistory.add(StudyDecision(
      wordId: word.id,
      previousState: previousState,
      decision: state,
    ));
    if (state == StudyState.memorized) {
      memorized++;
    } else {
      reviewed.add(word.term);
      final insertAt = queue.isEmpty ? 0 : Random().nextInt(queue.length) + 1;
      queue.insert(insertAt, word);
    }
    await widget.store.mark(word, state);
    revealed = false;
    dragY = 0;
    dismissing = false;
    if (queue.isEmpty) {
      if (activeBookId != null && activeSessionIndexes.isNotEmpty) {
        await widget.store
            .completeSessions(activeBookId!, activeSessionIndexes);
      } else {
        await widget.store.completeCurrentSession();
      }
      await widget.store.clearActiveStudy();
    } else {
      await persistStudy();
    }
    if (mounted) setState(() {});
  }

  void finishDrag(DragEndDetails details) {
    if (dismissing) return;
    final velocity = details.primaryVelocity ?? 0;
    final towardNegative = dragY < -90 || velocity < -650;
    final towardPositive = dragY > 90 || velocity > 650;
    if (!towardNegative && !towardPositive) {
      setState(() {
        dragging = false;
        dragY = 0;
      });
      return;
    }
    final positive = towardPositive;
    final state = stateForDirection(positive);
    final screenSize = MediaQuery.sizeOf(context);
    final dismissDistance =
        horizontalSwipe ? screenSize.width * 1.4 : screenSize.height * 1.25;

    setState(() {
      dragging = false;
      dismissing = true;
      dragY = positive ? dismissDistance : -dismissDistance;
    });
    Future<void>.delayed(const Duration(milliseconds: 280), () async {
      if (!mounted) return;
      await decide(state);
    });
  }

  void cancelDrag() {
    setState(() {
      dragging = false;
      dragY = 0;
    });
  }

  Future<void> copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('“$text” 복사 완료'),
        duration: const Duration(milliseconds: 1000),
      ),
    );
  }

  Future<void> editCurrentWord() async {
    if (queue.isEmpty) return;
    final current = queue.first;
    final updated = await _showWordEditor(context, current);
    if (!mounted || updated == null) return;
    await widget.store.updateWord(updated);
    final index = queue.indexWhere((word) => word.id == updated.id);
    if (index >= 0) queue[index] = updated;
    if (lastWord?.id == updated.id) lastWord = updated;
    if (mounted) setState(() {});
  }

  Future<void> editCardFontSizes() async {
    if (queue.isEmpty) return;
    final changed = await showCardFontSizeEditor(
      context,
      widget.store,
      previewWord: queue.first,
    );
    if (changed && mounted) setState(() {});
  }

  Widget cardFace(Word word, bool back) => Padding(
        padding: const EdgeInsets.all(26),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                  color:
                      back ? const Color(0xFFBFDBFE) : const Color(0xFFE5E5EA),
                  borderRadius: BorderRadius.circular(99))),
          const SizedBox(height: 34),
          Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(width: 40),
              Flexible(
                child: _TappableHanTerm(
                  term: word.term,
                  style: TextStyle(
                      color: ink,
                      fontSize: widget.store.termFontSize,
                      fontFamily: japaneseFontFamily(widget.store),
                      fontWeight: FontWeight.w800),
                  onCharacterTap: copyText,
                ),
              ),
              SizedBox(
                width: 40,
                child: IconButton(
                  key: const ValueKey('copy-word'),
                  tooltip: '단어 복사',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => copyText(word.term),
                  icon: const Icon(Icons.copy_outlined,
                      size: 18, color: Color(0xFF8E8E93)),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          if (back) ...[
            Text(word.meaning,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: widget.store.meaningFontSize,
                    fontFamily: japaneseFontFamily(widget.store),
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(word.reading,
                style: TextStyle(
                    color: const Color(0xFF8E8E93),
                    fontSize: widget.store.readingFontSize,
                    fontFamily:
                        japaneseFontFamily(widget.store) ?? 'monospace')),
            if (word.example.isNotEmpty) ...[
              const SizedBox(height: 28),
              Text(word.example,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: widget.store.exampleFontSize,
                      fontFamily: japaneseFontFamily(widget.store))),
              const SizedBox(height: 6),
              Text(word.exampleMeaning,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.black54,
                      fontSize: widget.store.exampleMeaningFontSize,
                      fontFamily: japaneseFontFamily(widget.store))),
            ],
          ] else
            Text(word.reading,
                style: TextStyle(
                    color: const Color(0xFF8E8E93),
                    fontSize: widget.store.readingFontSize,
                    fontFamily:
                        japaneseFontFamily(widget.store) ?? 'monospace')),
          const Spacer(),
          Text(back ? '탭하여 앞면 보기' : '탭하여 뒤집기',
              style: const TextStyle(color: Color(0x338E8E93), fontSize: 11)),
        ]),
      );

  Future<void> undo() async {
    if (undoHistory.isEmpty) return;
    final undone = undoHistory.removeLast();
    final word = widget.store.books
        .expand((book) => book.words)
        .where((item) => item.id == undone.wordId)
        .firstOrNull;
    if (word == null) return;
    queue.removeWhere((item) => item.id == word.id);
    queue.insert(0, word);
    if (undone.decision == StudyState.memorized) memorized--;
    if (undone.decision == StudyState.review &&
        !undoHistory.any((item) =>
            item.wordId == word.id && item.decision == StudyState.review)) {
      reviewed.remove(word.term);
    }
    await widget.store.mark(word, undone.previousState);
    final previous = undoHistory.lastOrNull;
    lastWord = previous == null
        ? null
        : widget.store.books
            .expand((book) => book.words)
            .where((item) => item.id == previous.wordId)
            .firstOrNull;
    lastState = previous?.decision;
    await persistStudy();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (queue.isEmpty) {
      return ResultPage(
          total: total,
          success: memorized,
          review: reviewed.length,
          title: '카드 학습 완료');
    }
    final word = queue.first;
    final nextWord = queue.length > 1 ? queue[1] : null;
    final selectedBook = activeBookId == null
        ? null
        : widget.store.books
            .where((book) => book.id == activeBookId)
            .firstOrNull;
    final sessionLabel = selectedBook == null || activeSessionIndexes.isEmpty
        ? '복습'
        : activeSessionIndexes
            .map((index) =>
                selectedBook.sessions(widget.store.sessionSize)[index].label)
            .join(' + ');
    final dragProgress = (dragY.abs() / 150).clamp(0.0, 1.0);
    final dragState = dragY == 0 ? null : stateForDirection(dragY > 0);
    final dragColor = dragState == StudyState.memorized
        ? Color.lerp(Colors.white, const Color(0xFFCFF2D8), dragProgress)!
        : dragState == StudyState.review
            ? Color.lerp(Colors.white, const Color(0xFFFFE8E6), dragProgress)!
            : Colors.white;
    final negativeColor =
        stateForDirection(false) == StudyState.memorized ? sea : coral;
    final positiveColor =
        stateForDirection(true) == StudyState.memorized ? sea : coral;
    return PopScope(
      canPop: exiting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) exitStudy();
      },
      child: Scaffold(
        body: AnimatedContainer(
          key: const ValueKey('study-card-background'),
          duration:
              dragging ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          decoration: BoxDecoration(color: dragColor),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(children: [
                Row(children: [
                  _RoundIconButton(icon: Icons.arrow_back, onTap: exitStudy),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(
                            '${selectedBook?.name ?? '기본 단어장'} · $sessionLabel',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Color(0xFF8E8E93), fontSize: 12)),
                        Text('${queue.length}개 남음',
                            style: const TextStyle(
                                color: ink,
                                fontSize: 14,
                                height: 1.15,
                                fontWeight: FontWeight.w800)),
                      ])),
                  _RoundIconButton(
                      icon: Icons.edit_outlined, onTap: editCurrentWord),
                  const SizedBox(width: 6),
                  _RoundIconButton(
                      icon: Icons.format_size, onTap: editCardFontSizes),
                  const SizedBox(width: 6),
                  _RoundIconButton(
                      icon: Icons.undo,
                      onTap: undoHistory.isEmpty ? null : undo),
                ]),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                    value: total == 0 ? 0 : memorized / total,
                    minHeight: 5,
                    borderRadius: BorderRadius.circular(99),
                    backgroundColor: const Color(0xFFE5E5EA)),
                const SizedBox(height: 5),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('$memorized 외움',
                          style: const TextStyle(
                              color: Color(0xFF8E8E93), fontSize: 11)),
                      Text('$total 전체',
                          style: const TextStyle(
                              color: Color(0xFF8E8E93), fontSize: 11)),
                    ]),
                const SizedBox(height: 12),
                if (horizontalSwipe)
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _SwipeHint(
                            icon: Icons.keyboard_arrow_left,
                            color: negativeColor),
                        _SwipeHint(
                            icon: Icons.keyboard_arrow_right,
                            color: positiveColor),
                      ])
                else
                  _SwipeHint(
                      icon: Icons.keyboard_arrow_up, color: negativeColor),
                const SizedBox(height: 12),
                Expanded(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (nextWord != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              key: const ValueKey('next-study-card'),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(24),
                                border:
                                    Border.all(color: const Color(0x14000000)),
                                boxShadow: const [
                                  BoxShadow(
                                      color: Color(0x10000000),
                                      blurRadius: 14,
                                      offset: Offset(0, 7))
                                ],
                              ),
                              child: cardFace(nextWord, false),
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: dismissing,
                          child: GestureDetector(
                            key: const ValueKey('study-card'),
                            onTap: () {
                              setState(() => revealed = !revealed);
                              persistStudy();
                            },
                            onVerticalDragStart: horizontalSwipe
                                ? null
                                : (_) => setState(() => dragging = true),
                            onVerticalDragUpdate: horizontalSwipe
                                ? null
                                : (details) => setState(() {
                                      dragY = (dragY + details.delta.dy)
                                          .clamp(-220.0, 220.0);
                                    }),
                            onVerticalDragCancel:
                                horizontalSwipe ? null : cancelDrag,
                            onVerticalDragEnd:
                                horizontalSwipe ? null : finishDrag,
                            onHorizontalDragStart: horizontalSwipe
                                ? (_) => setState(() => dragging = true)
                                : null,
                            onHorizontalDragUpdate: horizontalSwipe
                                ? (details) => setState(() {
                                      dragY = (dragY + details.delta.dx)
                                          .clamp(-220.0, 220.0);
                                    })
                                : null,
                            onHorizontalDragCancel:
                                horizontalSwipe ? cancelDrag : null,
                            onHorizontalDragEnd:
                                horizontalSwipe ? finishDrag : null,
                            child: TweenAnimationBuilder<double>(
                              key: ValueKey('active-card-${word.id}'),
                              tween: Tween(begin: 0, end: revealed ? pi : 0),
                              duration: const Duration(milliseconds: 420),
                              curve: Curves.easeInOutCubic,
                              builder: (context, angle, _) {
                                final back = angle > pi / 2;
                                return Transform(
                                  alignment: Alignment.center,
                                  transform: Matrix4.identity()
                                    ..setEntry(3, 2, 0.0012)
                                    ..rotateY(angle),
                                  child: AnimatedContainer(
                                    key: const ValueKey('study-card-surface'),
                                    duration: dragging
                                        ? Duration.zero
                                        : Duration(
                                            milliseconds:
                                                dismissing ? 280 : 180),
                                    curve: dismissing
                                        ? Curves.easeInCubic
                                        : Curves.easeOutCubic,
                                    width: double.infinity,
                                    transformAlignment: Alignment.centerRight,
                                    transform: Matrix4.identity()
                                      ..setTranslationRaw(
                                          horizontalSwipe ? dragY : 0.0,
                                          horizontalSwipe ? 0.0 : dragY,
                                          0.0)
                                      ..rotateZ((horizontalSwipe ? 1 : -1) *
                                          dragY.clamp(-220.0, 220.0) /
                                          1800),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                          color: const Color(0x14000000)),
                                      boxShadow: const [
                                        BoxShadow(
                                            color: Color(0x18000000),
                                            blurRadius: 22,
                                            offset: Offset(0, 10))
                                      ],
                                    ),
                                    child: Transform(
                                      alignment: Alignment.center,
                                      transform:
                                          Matrix4.rotationY(back ? pi : 0),
                                      child: cardFace(word, back),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (!horizontalSwipe)
                  _SwipeHint(
                      icon: Icons.keyboard_arrow_down, color: positiveColor),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? .35 : 1,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(99),
          child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0x14000000)),
                  shape: BoxShape.circle),
              child: Icon(icon, color: const Color(0xFF8E8E93), size: 17)),
        ),
      );
}

class _TappableHanTerm extends StatelessWidget {
  const _TappableHanTerm({
    required this.term,
    required this.style,
    required this.onCharacterTap,
  });

  final String term;
  final TextStyle style;
  final ValueChanged<String> onCharacterTap;

  @override
  Widget build(BuildContext context) {
    final characters = term.runes.map(String.fromCharCode).toList();
    return Text.rich(
      key: const ValueKey('tappable-study-term'),
      TextSpan(
        style: style,
        children: [
          for (var index = 0; index < characters.length; index++)
            if (isHanCharacter(characters[index]))
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  key: ValueKey('copy-han-$index'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onCharacterTap(characters[index]),
                  child: Text(characters[index], style: style),
                ),
              )
            else
              TextSpan(text: characters[index]),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _SwipeHint extends StatelessWidget {
  const _SwipeHint({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(99)),
        child: Icon(icon, size: 20, color: color.withValues(alpha: .55)),
      );
}

class QuizPage extends StatefulWidget {
  const QuizPage({
    super.key,
    required this.store,
    this.words,
    this.bookId,
    this.sessionIndexes = const [],
  });
  final VocaStore store;
  final List<Word>? words;
  final String? bookId;
  final List<int> sessionIndexes;

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  final controller = TextEditingController();
  late final List<Word> queue;
  late final int total;
  final reviewed = <String>{};
  var correct = 0;
  var feedback = '';
  var waiting = false;

  @override
  void initState() {
    super.initState();
    queue = List.of(widget.words ?? widget.store.nextWords())..shuffle();
    total = queue.length;
  }

  Future<void> check({bool dontKnow = false}) async {
    if (waiting) {
      setState(() {
        waiting = false;
        feedback = '';
        controller.clear();
      });
      return;
    }
    final input = controller.text.trim();
    if (!dontKnow && input.isEmpty) return;
    final word = queue.removeAt(0);
    final isCorrect =
        !dontKnow && word.meaning.toLowerCase().contains(input.toLowerCase());
    if (isCorrect) {
      correct++;
      await widget.store.mark(word, StudyState.memorized);
      feedback = '정답이에요!\n${word.meaning}  [${word.reading}]';
    } else {
      reviewed.add(word.term);
      await widget.store.mark(word, StudyState.review);
      queue.insert(
          queue.isEmpty ? 0 : Random().nextInt(queue.length) + 1, word);
      feedback = '다시 만나볼게요.\n정답: ${word.meaning}  [${word.reading}]';
    }
    waiting = true;
    if (queue.isEmpty) {
      if (widget.bookId != null && widget.sessionIndexes.isNotEmpty) {
        await widget.store
            .completeSessions(widget.bookId!, widget.sessionIndexes);
      } else {
        await widget.store.completeCurrentSession();
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (queue.isEmpty) {
      return ResultPage(
          total: total,
          success: correct,
          review: reviewed.length,
          title: '퀴즈 완료');
    }
    final word = queue.first;
    return Scaffold(
      appBar: AppBar(title: const Text('타이핑 퀴즈'), backgroundColor: mist),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        LinearProgressIndicator(
            value: correct / total, borderRadius: BorderRadius.circular(10)),
        const SizedBox(height: 36),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(children: [
                  Text(word.term,
                      style: const TextStyle(
                          color: ink,
                          fontSize: 34,
                          fontWeight: FontWeight.w800)),
                  if (word.example.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(word.example,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.black54))
                  ],
                ]))),
        const SizedBox(height: 20),
        TextField(
            controller: controller,
            enabled: !waiting,
            autofocus: true,
            onSubmitted: (_) => check(),
            decoration: const InputDecoration(hintText: '뜻을 입력하세요')),
        const SizedBox(height: 14),
        FilledButton(
            onPressed: check,
            child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(waiting ? '다음 문제' : '정답 확인'))),
        if (!waiting)
          TextButton(
              onPressed: () => check(dontKnow: true),
              child: const Text('모르겠어요')),
        if (feedback.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(feedback,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 17, height: 1.6, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

class ResultPage extends StatelessWidget {
  const ResultPage(
      {super.key,
      required this.total,
      required this.success,
      required this.review,
      required this.title});
  final int total;
  final int success;
  final int review;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
            child: Center(
                child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.auto_awesome, color: coral, size: 54),
            const SizedBox(height: 20),
            Text(title,
                style: const TextStyle(
                    color: ink, fontSize: 30, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Text('${total == 0 ? 0 : (success / total * 100).round()}%',
                style: const TextStyle(
                    color: sea, fontSize: 60, fontWeight: FontWeight.w900)),
            Text('알겠어요 $success개  ·  다시 보기 $review개',
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 34),
            FilledButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.home),
                label: const Text('홈으로')),
          ]),
        ))),
      );
}

class LegacyBooksPage extends StatelessWidget {
  const LegacyBooksPage(
      {super.key, required this.store, required this.refresh});
  final VocaStore store;
  final VoidCallback refresh;

  Future<void> importCsv(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['csv'], withData: true);
    if (result == null ||
        result.files.single.bytes == null ||
        !context.mounted) {
      return;
    }
    final words = parseWordsCsv(
        utf8.decode(result.files.single.bytes!, allowMalformed: true));
    if (words.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('읽을 수 있는 단어가 없습니다.')));
      return;
    }
    final name = await _askText(
        context,
        '단어장 이름',
        result.files.single.name
            .replaceAll(RegExp(r'\.csv$', caseSensitive: false), ''));
    if (name == null) return;
    await store.addBook(name, words);
    refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: mist,
        appBar: AppBar(
            title: const Text('내 단어장',
                style: TextStyle(fontWeight: FontWeight.w800)),
            backgroundColor: mist,
            actions: [
              IconButton(
                  onPressed: () async {
                    final name = await _askText(context, '새 단어장', '나의 단어장');
                    if (name == null || name.trim().isEmpty) return;
                    await store.addBook(name, []);
                    refresh();
                  },
                  icon: const Icon(Icons.add),
                  tooltip: '빈 단어장 만들기'),
              IconButton(
                  onPressed: () => importCsv(context),
                  icon: const Icon(Icons.file_upload_outlined),
                  tooltip: 'CSV 가져오기')
            ]),
        body: ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: store.books.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final book = store.books[index];
            final selected = book.id == store.quickBook.id;
            return Card(
                child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              leading: CircleAvatar(
                  backgroundColor: selected ? sea : const Color(0xFFE8EFEE),
                  foregroundColor: selected ? Colors.white : ink,
                  child: const Icon(Icons.menu_book)),
              title: Text(book.name,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                  '${book.words.length}개 단어 · ${store.completedCount(book)}/${store.sessionCount(book)} 세션'),
              trailing: book.id == 'default'
                  ? (selected
                      ? const Icon(Icons.check_circle, color: sea)
                      : null)
                  : PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'select') {
                          await store.selectQuickBook(book.id);
                        }
                        if (value == 'delete') {
                          await store.deleteBook(book.id);
                        }
                        refresh();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                            value: 'select', child: Text('빠른 학습으로 선택')),
                        PopupMenuItem(value: 'delete', child: Text('삭제'))
                      ],
                    ),
              onTap: () async {
                await store.selectQuickBook(book.id);
                if (!context.mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BookDetailPage(
                      store: store,
                      bookId: book.id,
                      onChanged: refresh,
                    ),
                  ),
                );
                refresh();
              },
            ));
          },
        ),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => importCsv(context),
            icon: const Icon(Icons.add),
            label: const Text('CSV 가져오기')),
      );
}

class BooksPage extends StatefulWidget {
  const BooksPage({super.key, required this.store, required this.refresh});

  final VocaStore store;
  final VoidCallback refresh;

  @override
  State<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<BooksPage> {
  var editMode = false;
  var searchQuery = '';
  final searchController = TextEditingController();
  final expandedBookIds = <String>{};
  Timer? searchTimer;
  late WordSearchSession searchSession;
  List<WordSearchHit> searchResults = const [];

  @override
  void initState() {
    super.initState();
    searchSession = widget.store.wordSearch.createSession();
  }

  @override
  void didUpdateWidget(covariant BooksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      searchSession = widget.store.wordSearch.createSession();
      searchResults = const [];
    }
  }

  @override
  void dispose() {
    searchTimer?.cancel();
    searchController.dispose();
    super.dispose();
  }

  void onSearchChanged(String value) {
    searchTimer?.cancel();
    setState(() => searchQuery = value);
    if (value.trim().isEmpty) {
      searchSession.reset();
      setState(() => searchResults = const []);
      return;
    }
    searchTimer = Timer(const Duration(milliseconds: 120), runSearch);
  }

  void runSearch() {
    final results = searchSession.search(searchQuery);
    if (mounted) setState(() => searchResults = results);
  }

  void startCustomOrder() {
    searchTimer?.cancel();
    searchController.clear();
    searchSession.reset();
    setState(() {
      searchQuery = '';
      searchResults = const [];
      editMode = true;
    });
  }

  Future<void> sortByName() async {
    await widget.store.sortBooksByName();
    if (!mounted) return;
    if (searchQuery.trim().isNotEmpty) runSearch();
    widget.refresh();
  }

  Future<void> editWord(Word word) async {
    final updated = await _showWordEditor(context, word);
    if (!mounted || updated == null) return;
    await widget.store.updateWord(updated);
    if (!mounted) return;
    if (searchQuery.trim().isNotEmpty) runSearch();
    widget.refresh();
  }

  Future<void> renameBook(WordBook book) async {
    final name = await _askText(context, '단어장 이름', book.name);
    if (!mounted || name == null || name.trim().isEmpty) return;
    book.name = name.trim();
    await widget.store.updateBook(book);
    if (!mounted) return;
    if (searchQuery.trim().isNotEmpty) runSearch();
    widget.refresh();
  }

  Future<void> toggleFavorite(WordBook book) async {
    book.isFavorite = !book.isFavorite;
    await widget.store.updateBook(book);
    if (!mounted) return;
    setState(() {});
    widget.refresh();
  }

  Future<void> confirmDelete(WordBook book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: coral, size: 32),
        title: const Text('단어장을 삭제할까요?'),
        content: Text(
            '“${book.name}”\n${book.words.length}개 단어가 함께 삭제되며 복구할 수 없습니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: coral),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await widget.store.deleteBook(book.id);
    if (!mounted) return;
    if (searchQuery.trim().isNotEmpty) runSearch();
    widget.refresh();
  }

  Future<void> showAddOptions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('새 단어장 만들기'),
              onTap: () => Navigator.pop(context, 'new'),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('CSV/Excel 가져오기'),
              subtitle: const Text('.csv, .xlsx'),
              onTap: () => Navigator.pop(context, 'import'),
            ),
          ]),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'new') await addBook();
    if (action == 'import') await importFile();
  }

  Future<void> addBook() async {
    final name = await _askText(context, '새 단어장', '나의 단어장');
    if (!mounted || name == null || name.trim().isEmpty) return;
    await widget.store.addBook(name, []);
    if (!mounted) return;
    widget.refresh();
  }

  Future<void> importFile() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'xlsx'],
        withData: true);
    if (result == null || result.files.single.bytes == null || !mounted) return;
    final file = result.files.single;
    final extension = file.extension?.toLowerCase();
    List<Word> words;
    try {
      words = extension == 'xlsx'
          ? parseWordsXlsx(file.bytes!)
          : parseWordsCsv(utf8.decode(file.bytes!, allowMalformed: true));
    } catch (_) {
      words = [];
    }
    if (words.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('읽을 수 있는 단어가 없습니다. 파일 양식을 확인해 주세요.')));
      return;
    }
    final name = await _askText(
        context,
        '단어장 이름',
        file.name
            .replaceAll(RegExp(r'\.(csv|xlsx)$', caseSensitive: false), ''));
    if (!mounted || name == null) return;
    await widget.store.addBook(name, words);
    if (!mounted) return;
    widget.refresh();
  }

  Future<void> openBook(WordBook book) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailPage(
            store: widget.store, bookId: book.id, onChanged: widget.refresh),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> openSession(WordBook book, int sessionIndex) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WordListPage(
          store: widget.store,
          bookId: book.id,
          sessionIndex: sessionIndex,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget bookCard(WordBook book, int index) => Padding(
        key: ValueKey(book.id),
        padding: const EdgeInsets.only(bottom: 10),
        child: Card(
          key: ValueKey('book-card-${book.id}'),
          color: isBookCompleted(widget.store, book)
              ? const Color(0xFFEDEDED)
              : Colors.white,
          child: Column(children: [
            SizedBox(
              height: 76,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                        color: const Color(0x1A34C759),
                        borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.menu_book_outlined,
                        color: sea, size: 20)),
                title: Text(book.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800)),
                subtitle: Text(
                    '${book.words.length}단어 · ${widget.store.sessionCount(book)}세션',
                    style: const TextStyle(
                        color: Color(0xFF8E8E93), fontSize: 11)),
                trailing: editMode
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(
                                width: 34, height: 40),
                            onPressed: () => renameBook(book),
                            icon: const Icon(Icons.edit_outlined,
                                size: 18, color: Color(0xFF8E8E93))),
                        if (book.id != 'default')
                          IconButton(
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints.tightFor(
                                  width: 34, height: 40),
                              onPressed: () => confirmDelete(book),
                              icon: const Icon(Icons.delete_outline,
                                  size: 18, color: coral)),
                        ReorderableDragStartListener(
                          index: index,
                          child: const SizedBox(
                              width: 30,
                              height: 40,
                              child: Icon(Icons.drag_handle,
                                  size: 20, color: Color(0xFF8E8E93))),
                        ),
                      ])
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          key: ValueKey('favorite-${book.id}'),
                          tooltip: book.isFavorite ? '즐겨찾기 해제' : '즐겨찾기',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                              width: 38, height: 40),
                          onPressed: () => toggleFavorite(book),
                          icon: Icon(
                            book.isFavorite ? Icons.star : Icons.star_border,
                            size: 21,
                            color: book.isFavorite
                                ? const Color(0xFFFFB800)
                                : const Color(0xFF8E8E93),
                          ),
                        ),
                        AnimatedRotation(
                          turns: expandedBookIds.contains(book.id) ? .5 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: const Icon(Icons.keyboard_arrow_down,
                              size: 20, color: Color(0xFF8E8E93)),
                        ),
                      ]),
                onTap: editMode
                    ? null
                    : () => setState(() => expandedBookIds.contains(book.id)
                        ? expandedBookIds.remove(book.id)
                        : expandedBookIds.add(book.id)),
                onLongPress: editMode ? null : importFile,
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: !expandedBookIds.contains(book.id) || editMode
                  ? const SizedBox.shrink()
                  : Column(children: [
                      const Divider(height: 1),
                      ...book.sessions(widget.store.sessionSize).map(
                            (session) => Material(
                              color: widget.store.isSessionCompleted(
                                      book.id, session.index)
                                  ? const Color(0xFFEDEDED)
                                  : Colors.transparent,
                              child: ListTile(
                                key: ValueKey(
                                    'book-${book.id}-session-${session.index}'),
                                dense: true,
                                contentPadding:
                                    const EdgeInsets.only(left: 58, right: 14),
                                title: Text(session.label,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700)),
                                subtitle: Text(
                                    '${session.memorizedCount}/${session.words.length} 단어'),
                                trailing: const Icon(Icons.chevron_right,
                                    color: Color(0xFF8E8E93), size: 18),
                                onTap: () => openSession(book, session.index),
                              ),
                            ),
                          ),
                      const Divider(height: 1),
                      TextButton.icon(
                        onPressed: () => openBook(book),
                        icon: const Icon(Icons.menu_book_outlined, size: 17),
                        label: const Text('단어장 전체 보기'),
                      ),
                      const SizedBox(height: 4),
                    ]),
            ),
          ]),
        ),
      );

  Widget buildSearchResults() {
    final results = searchResults;
    if (results.isEmpty) {
      return const Center(child: Text('전체 단어장에 검색 결과가 없습니다.'));
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final hit = results[index];
        final book = hit.book;
        final word = hit.word;
        return Card(
          child: ListTile(
            key: ValueKey('global-search-result-${word.id}'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: const Color(0x1A34C759),
                    borderRadius: BorderRadius.circular(11)),
                child:
                    const Icon(Icons.menu_book_outlined, color: sea, size: 18)),
            title:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                constraints: const BoxConstraints(maxWidth: 170),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: const Color(0x1A34C759),
                    borderRadius: BorderRadius.circular(99)),
                child: Text(book.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: sea, fontSize: 10, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 4),
              Text(word.term,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            subtitle: Text('${word.reading}\n${word.meaning}'),
            isThreeLine: true,
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => editWord(word),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final searching = searchQuery.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: mist,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
        child: Column(children: [
          Row(children: [
            const Expanded(
                child: Text('단어장',
                    style: TextStyle(
                        color: ink,
                        fontSize: 24,
                        fontWeight: FontWeight.w800))),
            PopupMenuButton<String>(
              tooltip: '단어장 정렬',
              icon: const Icon(Icons.sort, size: 21),
              onSelected: (value) {
                if (value == 'name') sortByName();
                if (value == 'custom') startCustomOrder();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'name', child: Text('이름 오름차순 (가나다/A-Z)')),
                PopupMenuItem(value: 'custom', child: Text('직접 드래그해서 정렬')),
              ],
            ),
            InkWell(
              onTap: () {
                if (editMode) {
                  setState(() => editMode = false);
                } else {
                  startCustomOrder();
                }
              },
              borderRadius: BorderRadius.circular(99),
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: const Color(0x14000000)),
                      borderRadius: BorderRadius.circular(99)),
                  child: Text(editMode ? '완료' : '편집',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700))),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: showAddOptions,
              borderRadius: BorderRadius.circular(99),
              child: Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                      color: sea,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: Color(0x4034C759),
                            blurRadius: 8,
                            offset: Offset(0, 3))
                      ]),
                  child: const Icon(Icons.add, color: Colors.white, size: 22)),
            ),
          ]),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('global-word-search'),
            controller: searchController,
            enabled: !editMode,
            onChanged: onSearchChanged,
            decoration: InputDecoration(
              hintText: editMode ? '드래그 손잡이로 순서를 바꾸세요' : '전체 단어장에서 검색',
              prefixIcon:
                  Icon(editMode ? Icons.drag_handle : Icons.search, size: 20),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: searching
                ? buildSearchResults()
                : editMode
                    ? ReorderableListView.builder(
                        padding: EdgeInsets.zero,
                        buildDefaultDragHandles: false,
                        itemCount: widget.store.books.length,
                        onReorderItem: (oldIndex, newIndex) async {
                          await widget.store.reorderBooks(oldIndex, newIndex);
                          if (!mounted) return;
                          setState(() {});
                          widget.refresh();
                        },
                        itemBuilder: (_, index) =>
                            bookCard(widget.store.books[index], index),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: widget.store.books.length,
                        itemBuilder: (_, index) =>
                            bookCard(widget.store.books[index], index),
                      ),
          ),
        ]),
      ),
    );
  }
}

class BookDetailPage extends StatefulWidget {
  const BookDetailPage({
    super.key,
    required this.store,
    required this.bookId,
    required this.onChanged,
  });

  final VocaStore store;
  final String bookId;
  final VoidCallback onChanged;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  var searchQuery = '';
  Timer? searchTimer;
  late WordSearchSession searchSession;
  List<Word> searchResults = const [];

  @override
  void initState() {
    super.initState();
    searchSession =
        widget.store.wordSearch.createSession(bookId: widget.bookId);
  }

  @override
  void dispose() {
    searchTimer?.cancel();
    super.dispose();
  }

  WordBook get book =>
      widget.store.books.firstWhere((item) => item.id == widget.bookId);

  Future<void> editWord(Word word) async {
    final updated = await _showWordEditor(context, word);
    if (!mounted || updated == null) return;
    await widget.store.updateWord(updated);
    widget.onChanged();
    if (!mounted) return;
    if (searchQuery.trim().isNotEmpty) {
      runSearch();
    } else {
      setState(() {});
    }
  }

  void onSearchChanged(String value) {
    searchTimer?.cancel();
    setState(() => searchQuery = value);
    if (value.trim().isEmpty) {
      searchSession.reset();
      setState(() => searchResults = const []);
      return;
    }
    searchTimer = Timer(const Duration(milliseconds: 120), runSearch);
  }

  void runSearch() {
    final results = searchSession
        .search(searchQuery)
        .map((hit) => hit.word)
        .toList(growable: false);
    if (mounted) setState(() => searchResults = results);
  }

  Future<void> rename() async {
    final name = await _askText(context, '단어장 이름', book.name);
    if (name == null || name.trim().isEmpty) return;
    book.name = name.trim();
    await widget.store.updateBook(book);
    widget.onChanged();
    if (mounted) setState(() {});
  }

  Future<void> exportExcel() async {
    final safeName = book.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '단어장 Excel로 내보내기',
        fileName: '${safeName.isEmpty ? 'VocaFlow_단어장' : safeName}.xlsx',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        bytes: createWordBookXlsx(book),
      );
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Excel 파일로 내보냈습니다.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel 내보내기에 실패했습니다: $error')),
      );
    }
  }

  Future<void> editSession(StudySession session) async {
    final nameController = TextEditingController(text: session.label);
    var size = session.size;
    final result = await showModalBottomSheet<(String, int)?>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 22, 20, MediaQuery.viewInsetsOf(context).bottom + 22),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${session.label} 편집',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: '세션 이름')),
                const SizedBox(height: 16),
                Text('단어 수 $size개',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Slider(
                    value: size.toDouble(),
                    min: 5,
                    max: 100,
                    divisions: 19,
                    label: '$size',
                    onChanged: (value) =>
                        setModalState(() => size = value.round())),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('취소'))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: FilledButton(
                          onPressed: () => Navigator.pop(
                              context, (nameController.text.trim(), size)),
                          child: const Text('저장'))),
                ]),
              ]),
        ),
      ),
    );
    nameController.dispose();
    if (result == null) return;
    book.sessionOverrides[session.index] = SessionOverride(
      name: result.$1.isEmpty ? null : result.$1,
      size: result.$2,
    );
    await widget.store.updateBook(book);
    widget.onChanged();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sessions = book.sessions(widget.store.sessionSize);
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: rename,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
                child: Text(book.name,
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            const SizedBox(width: 6),
            const Icon(Icons.edit_outlined, size: 16, color: Colors.black45),
          ]),
        ),
        actions: [
          IconButton(
            tooltip: 'Excel로 내보내기',
            onPressed: exportExcel,
            icon: const Icon(Icons.file_download_outlined),
          ),
          const SizedBox(width: 6),
        ],
        backgroundColor: mist,
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            key: const ValueKey('word-search'),
            onChanged: onSearchChanged,
            decoration: const InputDecoration(
              hintText: '단어·뜻·발음·예문 검색',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? const Center(child: Text('이 단어장은 비어 있습니다. CSV/Excel을 가져와 주세요.'))
              : searchQuery.trim().isNotEmpty
                  ? searchResults.isEmpty
                      ? const Center(child: Text('검색 결과가 없습니다.'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: searchResults.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final word = searchResults[index];
                            return Card(
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                title: Text(word.term,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800)),
                                subtitle:
                                    Text('${word.reading}\n${word.meaning}'),
                                isThreeLine: true,
                                trailing:
                                    const Icon(Icons.edit_outlined, size: 19),
                                onTap: () => editWord(word),
                              ),
                            );
                          },
                        )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: sessions.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final session = sessions[index];
                        final completed = widget.store
                            .isSessionCompleted(book.id, session.index);
                        return Card(
                            color: completed
                                ? const Color(0xFFF0FDF4)
                                : Colors.white,
                            child: Column(children: [
                              ListTile(
                                contentPadding:
                                    const EdgeInsets.fromLTRB(16, 8, 10, 8),
                                leading: CircleAvatar(
                                  backgroundColor: completed
                                      ? const Color(0xFFDCFCE7)
                                      : const Color(0xFFE5E5EA),
                                  foregroundColor:
                                      completed ? sea : Colors.black45,
                                  child: Icon(completed
                                      ? Icons.check
                                      : Icons.school_outlined),
                                ),
                                title: Text(session.label,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                subtitle: Text(
                                    '${session.memorizedCount}/${session.words.length} 단어'),
                                trailing: completed
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 9, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFDCFCE7),
                                          borderRadius:
                                              BorderRadius.circular(99),
                                        ),
                                        child: const Text('완료',
                                            style: TextStyle(
                                                color: sea,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800)),
                                      )
                                    : const Icon(Icons.chevron_right),
                                onTap: () async {
                                  await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => WordListPage(
                                              store: widget.store,
                                              bookId: book.id,
                                              sessionIndex: session.index)));
                                  if (mounted) setState(() {});
                                  widget.onChanged();
                                },
                              ),
                              const Divider(height: 1),
                              Row(children: [
                                Expanded(
                                    child: TextButton.icon(
                                  onPressed: () async {
                                    await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => CardStudyPage(
                                                    store: widget.store,
                                                    words: session.words,
                                                    bookId: book.id,
                                                    sessionIndexes: [
                                                      session.index
                                                    ])));
                                    if (mounted) setState(() {});
                                  },
                                  icon: const Icon(Icons.style, size: 17),
                                  label: const Text('학습'),
                                )),
                                Expanded(
                                    child: TextButton.icon(
                                        onPressed: () => editSession(session),
                                        icon: const Icon(Icons.edit_outlined,
                                            size: 17),
                                        label: const Text('편집'))),
                              ]),
                            ]));
                      },
                    ),
        ),
      ]),
    );
  }
}

class WordListPage extends StatefulWidget {
  const WordListPage(
      {super.key,
      required this.store,
      required this.bookId,
      required this.sessionIndex});
  final VocaStore store;
  final String bookId;
  final int sessionIndex;

  @override
  State<WordListPage> createState() => _WordListPageState();
}

class _WordListPageState extends State<WordListPage> {
  WordBook get book =>
      widget.store.books.firstWhere((item) => item.id == widget.bookId);
  StudySession get session => book
      .sessions(widget.store.sessionSize)
      .firstWhere((item) => item.index == widget.sessionIndex);

  Future<void> editWord(Word word) async {
    final updated = await _showWordEditor(context, word);
    if (!mounted || updated == null) return;
    await widget.store.updateWord(updated);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(session.label), backgroundColor: mist),
        body: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: session.words.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final word = session.words[index];
            return Card(
                child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              title: Text(word.term,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text('${word.reading}\n${word.meaning}'),
              isThreeLine: true,
              trailing: _StatePill(state: word.state),
              onTap: () => editWord(word),
            ));
          },
        ),
      );
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.state});
  final StudyState state;

  @override
  Widget build(BuildContext context) {
    final label = switch (state) {
      StudyState.fresh => '새 단어',
      StudyState.memorized => '외움',
      StudyState.review => '복습'
    };
    final color = switch (state) {
      StudyState.fresh => Colors.black45,
      StudyState.memorized => sea,
      StudyState.review => coral
    };
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(99)),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w700)));
  }
}

class ProgressPage extends StatelessWidget {
  const ProgressPage({super.key, required this.store});
  final VocaStore store;

  @override
  Widget build(BuildContext context) {
    final words = store.books.expand((book) => book.words).toList();
    final memorized =
        words.where((word) => word.state == StudyState.memorized).length;
    final review =
        words.where((word) => word.state == StudyState.review).length;
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('학습 기록',
          style:
              TextStyle(color: ink, fontSize: 28, fontWeight: FontWeight.w800)),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(
            child: _Metric(
                label: '연속 학습', value: '${store.streak}일', color: coral)),
        const SizedBox(width: 12),
        Expanded(
            child: _Metric(label: '외운 단어', value: '$memorized', color: sea)),
      ]),
      const SizedBox(height: 12),
      _Metric(label: '다시 볼 단어', value: '$review', color: ink),
      const SizedBox(height: 24),
      const Text('단어장별 진행률',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      ...store.books.map((book) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
                child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(book.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          LinearProgressIndicator(
                              value: book.words.isEmpty
                                  ? 0
                                  : book.words
                                          .where((word) =>
                                              word.state ==
                                              StudyState.memorized)
                                          .length /
                                      book.words.length,
                              borderRadius: BorderRadius.circular(10)),
                        ]))),
          )),
    ]);
  }
}

class LegacySettingsPage extends StatelessWidget {
  const LegacySettingsPage(
      {super.key, required this.store, required this.refresh});
  final VocaStore store;
  final VoidCallback refresh;

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(20), children: [
        const Text('설정',
            style: TextStyle(
                color: ink, fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 20),
        Card(
            child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(children: [
              Row(children: [
                const Icon(Icons.view_carousel_outlined),
                const SizedBox(width: 14),
                const Expanded(child: Text('세션당 기본 단어 수')),
                Text('${store.sessionSize}개',
                    style: const TextStyle(
                        color: sea, fontWeight: FontWeight.w800)),
              ]),
              SizedBox(
                height: 110,
                child: CupertinoPicker(
                  itemExtent: 38,
                  scrollController: FixedExtentScrollController(
                      initialItem:
                          ((store.sessionSize - 5) / 5).round().clamp(0, 19)),
                  onSelectedItemChanged: (index) async {
                    await store.setSessionSize(5 + index * 5);
                    refresh();
                  },
                  children: List.generate(
                      20, (index) => Center(child: Text('${5 + index * 5}'))),
                ),
              ),
            ]),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('학습 목표'),
            subtitle: Text(store.targetDate == null
                ? 'D-day를 설정해 보세요'
                : '${store.targetName.isEmpty ? '목표일' : store.targetName} · ${_dDayText(store.dDay)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editTarget(context),
          ),
        ])),
        const SizedBox(height: 20),
        Card(
            child: ListTile(
          leading: const Icon(Icons.restart_alt, color: coral),
          title: const Text('학습 기록 초기화'),
          subtitle: const Text('단어장 자체는 삭제되지 않습니다.'),
          onTap: () async {
            final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                            title: const Text('학습 기록을 초기화할까요?'),
                            content: const Text('외움 상태와 완료한 세션 기록이 모두 지워집니다.'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('취소')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('초기화'))
                            ])) ??
                false;
            if (ok) {
              await store.resetProgress();
              refresh();
            }
          },
        )),
      ]);

  Future<void> _editTarget(BuildContext context) async {
    final name = await _askText(context, '목표 이름', store.targetName);
    if (name == null || !context.mounted) return;
    final date = await showDatePicker(
        context: context,
        initialDate:
            store.targetDate ?? DateTime.now().add(const Duration(days: 30)),
        firstDate: DateTime.now().subtract(const Duration(days: 365)),
        lastDate: DateTime.now().add(const Duration(days: 3650)));
    if (date == null) return;
    await store.setTarget(name, date);
    refresh();
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.refresh,
    this.autoBackup,
  });

  final VocaStore store;
  final VoidCallback refresh;
  final AutoBackupCoordinator? autoBackup;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  var signingIn = false;
  var syncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          firebaseReady &&
          FirebaseAuth.instance.currentUser != null &&
          widget.autoBackup?.initialized == false) {
        _setupAutoBackupAfterLogin();
      }
    });
  }

  Future<void> signInWithGoogle() async {
    if (!firebaseReady) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Firebase 초기화에 실패했습니다. 앱을 다시 실행해 주세요.')));
      return;
    }
    setState(() => signingIn = true);
    try {
      await ensureGoogleSignInInitialized();
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: const ['email', 'profile'],
      );
      final googleAuth = account.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (mounted) {
        setState(() {});
        await _setupAutoBackupAfterLogin();
      }
    } on GoogleSignInException catch (error) {
      if (!mounted ||
          error.code == GoogleSignInExceptionCode.canceled ||
          error.code == GoogleSignInExceptionCode.interrupted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Google 로그인에 실패했습니다. (${error.code.name})')));
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      final message = error.code == 'operation-not-allowed'
          ? 'Firebase 콘솔에서 Google 로그인을 먼저 사용 설정해 주세요.'
          : 'Google 로그인에 실패했습니다. (${error.code})';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => signingIn = false);
    }
  }

  Future<void> signOut() async {
    await FirebaseAuth.instance.signOut();
    await ensureGoogleSignInInitialized();
    await GoogleSignIn.instance.signOut();
    if (mounted) setState(() {});
  }

  Future<void> _setupAutoBackupAfterLogin() async {
    final coordinator = widget.autoBackup;
    if (coordinator == null || coordinator.initialized) return;
    setState(() => syncing = true);
    try {
      final hasCloud = await coordinator.hasCloudBackup();
      if (!mounted) return;
      InitialSyncChoice? choice;
      if (hasCloud) {
        choice = await showDialog<InitialSyncChoice>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('자동 백업 처음 설정'),
            content: const Text(
              '이 계정에 기존 백업이 있습니다. 이 기기의 데이터와 어떻게 맞출까요?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              OutlinedButton(
                onPressed: () =>
                    Navigator.pop(context, InitialSyncChoice.merge),
                child: const Text('클라우드 + 이 기기 합치기'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, InitialSyncChoice.cloudReplace),
                child: const Text('클라우드로 이 기기 교체'),
              ),
            ],
          ),
        );
        if (choice == null) return;
      }
      await coordinator.initialize(choice);
      widget.refresh();
      _showSnack('자동 백업을 켰습니다.');
    } catch (error) {
      _showSnack('자동 백업 설정에 실패했습니다. ($error)');
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> toggleAutoBackup(bool value) async {
    final coordinator = widget.autoBackup;
    if (coordinator == null) return;
    if (value && !coordinator.initialized) {
      await _setupAutoBackupAfterLogin();
      return;
    }
    await coordinator.setEnabled(value);
    if (mounted) setState(() {});
  }

  Future<void> uploadToCloud() async {
    final confirmed = await _confirm(
      title: '클라우드 백업',
      message: '현재 이 기기의 단어장과 학습 기록을 서버에 저장할까요?',
      action: '업로드',
    );
    if (!confirmed) return;
    await _runCloudTask(() async {
      final coordinator = widget.autoBackup;
      if (coordinator == null) {
        await CloudBackup().upload(widget.store);
        await widget.store.cloudChanges.clearPending();
      } else {
        await coordinator.manualFullUpload();
      }
      _showSnack('클라우드에 백업했습니다.');
    });
  }

  Future<void> restoreFromCloud() async {
    final confirmed = await _confirm(
      title: '클라우드 데이터 가져오기',
      message: '서버 데이터를 이 기기로 가져옵니다. 현재 기기의 데이터는 덮어써집니다.',
      action: '가져오기',
      destructive: true,
    );
    if (!confirmed) return;
    await _runCloudTask(() async {
      final coordinator = widget.autoBackup;
      if (coordinator == null) {
        final backup = await CloudBackup().downloadBackupJson();
        await widget.store.replaceWithBackupJson(backup);
        await widget.store.cloudChanges.clearPending();
      } else {
        await coordinator.manualRestore();
      }
      widget.refresh();
      _showSnack('클라우드 데이터를 가져왔습니다.');
    });
  }

  Future<void> viewCloudContents() async {
    if (!firebaseReady || FirebaseAuth.instance.currentUser == null) {
      _showSnack('먼저 Google로 로그인해 주세요.');
      return;
    }
    setState(() => syncing = true);
    try {
      final overview = await CloudBackup().loadOverview();
      if (!mounted) return;
      setState(() => syncing = false);
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _CloudBackupOverviewSheet(overview: overview),
      );
    } catch (error) {
      if (!mounted) return;
      final message = error is StateError
          ? '아직 클라우드에 저장된 백업이 없습니다.'
          : '클라우드 저장 내용을 불러오지 못했습니다. ($error)';
      _showSnack(message);
    } finally {
      if (mounted && syncing) setState(() => syncing = false);
    }
  }

  Future<void> _runCloudTask(Future<void> Function() task) async {
    if (!firebaseReady || FirebaseAuth.instance.currentUser == null) {
      _showSnack('먼저 Google로 로그인해 주세요.');
      return;
    }
    setState(() => syncing = true);
    try {
      await task();
    } catch (error) {
      if (!mounted) return;
      _showSnack('클라우드 작업에 실패했습니다. ($error)');
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(backgroundColor: coral)
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final user = firebaseReady ? FirebaseAuth.instance.currentUser : null;
    final auto = widget.autoBackup;
    final lastSuccess = auto?.lastSuccess?.toLocal();
    final lastSuccessText =
        lastSuccess == null ? '아직 없음' : lastSuccess.toString().substring(0, 16);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
      children: [
        const Text('설정',
            style: TextStyle(
                color: ink, fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 18),
        const _SectionTitle('계정'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  user == null
                      ? 'Google 계정으로 Firebase에 연결할 수 있어요.'
                      : '${user.email ?? user.displayName ?? '로그인된 사용자'} · 연결됨',
                  style:
                      const TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton(
                  onPressed: signingIn
                      ? null
                      : user == null
                          ? signInWithGoogle
                          : signOut,
                  style: OutlinedButton.styleFrom(
                      foregroundColor: ink,
                      backgroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFFDADCE0)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (signingIn)
                          const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          const _ChromeIcon(size: 20),
                        const SizedBox(width: 10),
                        Text(
                            signingIn
                                ? '로그인 중...'
                                : user == null
                                    ? 'Google로 로그인'
                                    : '로그아웃',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700)),
                      ]),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        const _SectionTitle('클라우드 백업'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  key: const ValueKey('auto-backup-setting'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('자동 백업',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  subtitle: const Text('변경 후 60초가 지나면 필요한 항목만 백업합니다.'),
                  value: auto?.enabled ?? false,
                  onChanged: syncing || user == null || auto == null
                      ? null
                      : toggleAutoBackup,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<AutoBackupNetworkPolicy>(
                  key: ValueKey(
                      'auto-backup-network-${auto?.networkPolicy.name ?? 'all'}'),
                  initialValue:
                      auto?.networkPolicy ?? AutoBackupNetworkPolicy.all,
                  decoration: const InputDecoration(
                    labelText: '자동 백업 네트워크',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: AutoBackupNetworkPolicy.all,
                      child: Text('모든 네트워크'),
                    ),
                    DropdownMenuItem(
                      value: AutoBackupNetworkPolicy.wifiOnly,
                      child: Text('Wi-Fi만'),
                    ),
                  ],
                  onChanged: user == null || auto == null
                      ? null
                      : (value) async {
                          if (value == null) return;
                          await auto.setNetworkPolicy(value);
                          if (mounted) setState(() {});
                        },
                ),
                const SizedBox(height: 12),
                Text('마지막 성공: $lastSuccessText',
                    style: const TextStyle(
                        color: Color(0xFF8E8E93), fontSize: 12)),
                Text(
                    '대기 중 변경: ${auto?.pendingCount ?? widget.store.cloudChanges.pendingCount}개',
                    style: const TextStyle(
                        color: Color(0xFF8E8E93), fontSize: 12)),
                if (auto?.isUploading == true)
                  const Text('증분 백업 중...',
                      style: TextStyle(color: sea, fontSize: 12)),
                if (auto?.lastError != null) ...[
                  const SizedBox(height: 4),
                  Text('마지막 오류: ${auto!.lastError}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: coral, fontSize: 12)),
                ],
                const Divider(height: 28),
                const Text(
                  '로그인한 계정에 단어장과 학습 기록을 저장합니다.',
                  style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton.icon(
                    onPressed: syncing || user == null ? null : uploadToCloud,
                    icon: syncing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(CupertinoIcons.cloud_upload, size: 18),
                    label: const Text('이 기기 데이터 업로드'),
                    style: FilledButton.styleFrom(
                      backgroundColor: sea,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed:
                        syncing || user == null ? null : restoreFromCloud,
                    icon: const Icon(CupertinoIcons.cloud_download, size: 18),
                    label: const Text('클라우드 데이터 가져오기'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ink,
                      side: const BorderSide(color: Color(0xFFDADCE0)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: TextButton.icon(
                    key: const ValueKey('view-cloud-contents'),
                    onPressed:
                        syncing || user == null ? null : viewCloudContents,
                    icon: const Icon(Icons.manage_search, size: 19),
                    label: const Text('클라우드에 저장된 내용 보기'),
                    style: TextButton.styleFrom(
                      foregroundColor: sea,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const _SectionTitle('학습 카드 조작'),
        Card(
          child: Column(children: [
            SwitchListTile.adaptive(
              key: const ValueKey('horizontal-swipe-setting'),
              secondary: const Icon(Icons.swap_horiz, color: sea),
              title: const Text('좌우 스와이프 모드',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              subtitle: Text(widget.store.horizontalSwipe
                  ? '오른쪽: 알아요 · 왼쪽: 몰라요'
                  : '위쪽: 알아요 · 아래쪽: 몰라요'),
              value: widget.store.horizontalSwipe,
              onChanged: (value) async {
                await widget.store.setHorizontalSwipe(value);
                widget.refresh();
                if (mounted) setState(() {});
              },
            ),
            const Divider(height: 1),
            SwitchListTile.adaptive(
              key: const ValueKey('reverse-swipe-setting'),
              secondary: const Icon(Icons.swap_calls, color: coral),
              title: const Text('판정 방향 반전',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              subtitle: const Text('알아요와 몰라요 방향을 서로 바꿉니다.'),
              value: widget.store.reverseSwipe,
              onChanged: (value) async {
                await widget.store.setReverseSwipe(value);
                widget.refresh();
                if (mounted) setState(() {});
              },
            ),
          ]),
        ),
        const SizedBox(height: 20),
        const _SectionTitle('학습 카드 글자 크기'),
        Card(
          child: ListTile(
            key: const ValueKey('card-font-size-setting'),
            leading: const Icon(Icons.format_size, color: sea),
            title: const Text('전체 및 항목별 크기',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            subtitle: Text(
                '단어 ${widget.store.termFontSize.round()} · 뜻 ${widget.store.meaningFontSize.round()}'),
            trailing: const Text('변경',
                style: TextStyle(
                    color: sea, fontSize: 12, fontWeight: FontWeight.w700)),
            onTap: editCardFontSizes,
          ),
        ),
        const SizedBox(height: 20),
        const _SectionTitle('일본어 글꼴'),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DropdownButtonFormField<String>(
              key: const ValueKey('japanese-font-setting'),
              initialValue: widget.store.japaneseFont,
              decoration: const InputDecoration(
                labelText: '일본어 명조체',
                prefixIcon: Icon(Icons.translate, color: sea),
                filled: false,
              ),
              items: const [
                DropdownMenuItem(value: 'system', child: Text('기본 글꼴')),
                DropdownMenuItem(
                    value: 'notoSerifJP', child: Text('Noto Serif JP')),
                DropdownMenuItem(
                    value: 'sourceHanSerifJP',
                    child: Text('Source Han Serif JP / 源ノ明朝')),
              ],
              onChanged: (value) async {
                if (value == null) return;
                await widget.store.setJapaneseFont(value);
                widget.refresh();
                if (mounted) setState(() {});
              },
            ),
          ),
        ),
        const SizedBox(height: 20),
        const _SectionTitle('기본 세션 크기'),
        Card(
          child: ListTile(
            key: const ValueKey('session-size-setting'),
            leading: const Icon(Icons.view_carousel_outlined, color: sea),
            title: const Text('세션당 기본 단어 수',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            subtitle: Text('현재 ${widget.store.sessionSize}개'),
            trailing: const Text('변경',
                style: TextStyle(
                    color: sea, fontSize: 12, fontWeight: FontWeight.w700)),
            onTap: editSessionSize,
          ),
        ),
        const SizedBox(height: 20),
        const _SectionTitle('기타'),
        Card(
          child: Column(children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.calendar_today_outlined,
                  color: sea, size: 17),
              title: const Text('D-day 설정',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              subtitle: widget.store.targetDate == null
                  ? null
                  : Text(_dDayText(widget.store.dDay),
                      style: const TextStyle(
                          color: Color(0xFF8E8E93), fontSize: 11)),
              trailing: const Text('설정',
                  style: TextStyle(
                      color: sea, fontSize: 12, fontWeight: FontWeight.w700)),
              onTap: editTarget,
            ),
          ]),
        ),
        const SizedBox(height: 48),
        const _SectionTitle('위험 영역'),
        Card(
          child: ListTile(
            key: const ValueKey('reset-study-data'),
            dense: true,
            title: const Text('학습 데이터 초기화',
                style: TextStyle(
                    color: coral, fontSize: 14, fontWeight: FontWeight.w700)),
            subtitle: const Text('외운 상태와 완료한 세션 기록을 모두 삭제합니다.'),
            trailing: const Icon(Icons.delete_outline, color: coral, size: 18),
            onTap: resetProgress,
          ),
        ),
      ],
    );
  }

  Future<void> editSessionSize() async {
    var selected = widget.store.sessionSize;
    final saved = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('기본 세션 크기 변경'),
          content: SizedBox(
            width: 240,
            height: 144,
            child: CupertinoPicker(
              itemExtent: 38,
              scrollController: FixedExtentScrollController(
                initialItem: ((selected - 5) / 5).round().clamp(0, 39),
              ),
              onSelectedItemChanged: (index) =>
                  setDialogState(() => selected = 5 + index * 5),
              children: List.generate(
                40,
                (index) => Center(child: Text('${5 + index * 5}개')),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소')),
            FilledButton(
                onPressed: () => Navigator.pop(context, selected),
                child: const Text('저장')),
          ],
        ),
      ),
    );
    if (saved == null || saved == widget.store.sessionSize) return;
    await widget.store.setSessionSize(saved);
    widget.refresh();
    if (mounted) setState(() {});
  }

  Future<void> editCardFontSizes() async {
    final changed = await showCardFontSizeEditor(context, widget.store);
    if (!changed) return;
    widget.refresh();
    if (mounted) setState(() {});
  }

  Future<void> editTarget() async {
    final date = await showDatePicker(
        context: context,
        initialDate: widget.store.targetDate ??
            DateTime.now().add(const Duration(days: 30)),
        firstDate: DateTime.now().subtract(const Duration(days: 365)),
        lastDate: DateTime.now().add(const Duration(days: 3650)));
    if (date == null) return;
    await widget.store.setTarget(widget.store.targetName, date);
    widget.refresh();
    if (mounted) setState(() {});
  }

  Future<void> resetProgress() async {
    final firstConfirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('학습 데이터를 초기화할까요?'),
            content: const Text('외운 상태와 완료한 세션 기록이 삭제됩니다.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('취소')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('초기화')),
            ],
          ),
        ) ??
        false;
    if (!firstConfirmed || !mounted) return;
    final secondConfirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('정말 초기화할까요?'),
            content: const Text('이 작업은 되돌릴 수 없습니다. 왼쪽의 초기화 버튼을 눌러 확정하세요.'),
            actions: [
              FilledButton(
                  key: const ValueKey('final-reset-confirm'),
                  style: FilledButton.styleFrom(backgroundColor: coral),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('초기화')),
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('취소')),
            ],
          ),
        ) ??
        false;
    if (!secondConfirmed) return;
    await widget.store.resetProgress();
    widget.refresh();
    if (mounted) setState(() {});
  }
}

class _CloudBackupOverviewSheet extends StatelessWidget {
  const _CloudBackupOverviewSheet({required this.overview});

  final CloudBackupOverview overview;

  String get fontLabel => switch (overview.japaneseFont) {
        'notoSerifJP' => 'Noto Serif JP',
        'sourceHanSerifJP' => 'Source Han Serif JP',
        _ => '기본 글꼴',
      };

  String get updatedAtLabel {
    final value = overview.updatedAt?.toLocal();
    if (value == null) return '시간 정보 없음';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}.${two(value.month)}.${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
        heightFactor: .84,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            const Text('클라우드에 저장된 내용',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('마지막 백업 $updatedAtLabel',
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: _CloudMetric(
                      label: '단어장', value: '${overview.books.length}개')),
              const SizedBox(width: 8),
              Expanded(
                  child: _CloudMetric(
                      label: '단어', value: '${overview.totalWords}개')),
              const SizedBox(width: 8),
              Expanded(
                  child: _CloudMetric(
                      label: '완료 세션',
                      value: '${overview.completedSessionCount}개')),
            ]),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('저장 방식',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 7),
                      const Text(
                        'Google 계정별 Firebase 공간에 단어장은 각각 분리하고, 단어·학습 상태·완료 세션·설정은 함께 저장합니다.',
                        style: TextStyle(
                            color: Color(0xFF8E8E93),
                            fontSize: 12,
                            height: 1.45),
                      ),
                      const Divider(height: 24),
                      Text(
                          '기본 세션 ${overview.sessionSize}개 · 학습일 ${overview.studyDayCount}일'),
                      const SizedBox(height: 5),
                      Text('일본어 글꼴 $fontLabel'),
                      if (overview.targetName.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text('학습 목표 ${overview.targetName}'),
                      ],
                    ]),
              ),
            ),
            const SizedBox(height: 18),
            const Text('저장된 단어장',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (overview.books.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('저장된 단어장이 없습니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF8E8E93))),
              )
            else
              ...overview.books.map((book) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        leading:
                            const Icon(Icons.menu_book_outlined, color: sea),
                        title: Text(book.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${book.wordCount}개 단어'),
                        trailing: book.isFavorite
                            ? const Icon(Icons.star,
                                color: Color(0xFFFFB800), size: 19)
                            : null,
                      ),
                    ),
                  )),
          ],
        ),
      );
}

class _CloudMetric extends StatelessWidget {
  const _CloudMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        decoration: BoxDecoration(
          color: const Color(0xFFF2F2F7),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(children: [
          Text(value,
              style: const TextStyle(color: ink, fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text(label,
              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 10)),
        ]),
      );
}

class _ChromeIcon extends StatelessWidget {
  const _ChromeIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _ChromeIconPainter()),
      );
}

class _ChromeIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final bounds = Rect.fromCircle(center: center, radius: radius);
    const colors = [Color(0xFFEA4335), Color(0xFFFBBC05), Color(0xFF34A853)];
    for (var index = 0; index < colors.length; index++) {
      canvas.drawArc(
        bounds,
        -pi / 2 + index * 2 * pi / 3,
        2 * pi / 3,
        true,
        Paint()..color = colors[index],
      );
    }
    canvas.drawCircle(center, radius * .47, Paint()..color = Colors.white);
    canvas.drawCircle(
        center, radius * .36, Paint()..color = const Color(0xFF4285F4));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                color: Color(0xFF8E8E93),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: .4)),
      );
}

Future<bool> showCardFontSizeEditor(
  BuildContext context,
  VocaStore store, {
  Word? previewWord,
}) async {
  final word = previewWord ??
      Word(
        term: '日本語',
        reading: 'にほんご',
        meaning: '일본어',
        example: '毎日、日本語を勉強します。',
        exampleMeaning: '매일 일본어를 공부합니다.',
      );
  var overall = 1.0;
  var term = store.termFontSize;
  var reading = store.readingFontSize;
  var meaning = store.meaningFontSize;
  var example = store.exampleFontSize;
  var exampleMeaning = store.exampleMeaningFontSize;
  final values = await showModalBottomSheet<List<double>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setModalState) => FractionallySizedBox(
        heightFactor: .94,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(children: [
            Row(children: [
              const Expanded(
                child: Text('학습 카드 글자 크기',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소')),
              const SizedBox(width: 4),
              FilledButton(
                key: const ValueKey('save-card-font-sizes'),
                onPressed: () => Navigator.pop(
                    context, [term, reading, meaning, example, exampleMeaning]),
                child: const Text('저장'),
              ),
            ]),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Column(children: [
                  Container(
                    key: const ValueKey('font-size-card-preview'),
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0x14000000)),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 18,
                            offset: Offset(0, 8)),
                      ],
                    ),
                    child: Column(children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('카드 미리보기',
                            style: TextStyle(
                                color: Color(0xFF8E8E93), fontSize: 11)),
                      ),
                      const SizedBox(height: 22),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox(width: 40),
                        Flexible(
                          child: Text(word.term,
                              key: const ValueKey('font-preview-term'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: ink,
                                  fontSize: term,
                                  fontFamily: japaneseFontFamily(store),
                                  fontWeight: FontWeight.w800)),
                        ),
                        const SizedBox(
                          width: 40,
                          child: Icon(Icons.copy_outlined,
                              size: 18, color: Color(0xFF8E8E93)),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Text(word.reading,
                          key: const ValueKey('font-preview-reading'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: const Color(0xFF8E8E93),
                              fontSize: reading,
                              fontFamily:
                                  japaneseFontFamily(store) ?? 'monospace')),
                      const SizedBox(height: 18),
                      Text(word.meaning,
                          key: const ValueKey('font-preview-meaning'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: meaning,
                              fontFamily: japaneseFontFamily(store),
                              fontWeight: FontWeight.w700)),
                      if (word.example.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(word.example,
                            key: const ValueKey('font-preview-example'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: example,
                                fontFamily: japaneseFontFamily(store))),
                        const SizedBox(height: 6),
                        Text(word.exampleMeaning,
                            key: const ValueKey('font-preview-example-meaning'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.black54,
                                fontSize: exampleMeaning,
                                fontFamily: japaneseFontFamily(store))),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 18),
                  _FontSizeSlider(
                    label: '전체 크기',
                    valueLabel: '${(overall * 100).round()}%',
                    value: overall,
                    min: .75,
                    max: 1.5,
                    divisions: 15,
                    onChanged: (value) => setModalState(() {
                      overall = value;
                      term = 32 * value;
                      reading = 14 * value;
                      meaning = 22 * value;
                      example = 16 * value;
                      exampleMeaning = 14 * value;
                    }),
                  ),
                  const Divider(),
                  _FontSizeSlider(
                    label: '단어',
                    valueLabel: '${term.round()}',
                    value: term,
                    min: 20,
                    max: 52,
                    divisions: 32,
                    onChanged: (value) => setModalState(() => term = value),
                  ),
                  _FontSizeSlider(
                    label: '발음',
                    valueLabel: '${reading.round()}',
                    value: reading,
                    min: 10,
                    max: 28,
                    divisions: 18,
                    onChanged: (value) => setModalState(() => reading = value),
                  ),
                  _FontSizeSlider(
                    label: '뜻',
                    valueLabel: '${meaning.round()}',
                    value: meaning,
                    min: 14,
                    max: 38,
                    divisions: 24,
                    onChanged: (value) => setModalState(() => meaning = value),
                  ),
                  _FontSizeSlider(
                    label: '예문',
                    valueLabel: '${example.round()}',
                    value: example,
                    min: 11,
                    max: 28,
                    divisions: 17,
                    onChanged: (value) => setModalState(() => example = value),
                  ),
                  _FontSizeSlider(
                    label: '예문 뜻',
                    valueLabel: '${exampleMeaning.round()}',
                    value: exampleMeaning,
                    min: 10,
                    max: 26,
                    divisions: 16,
                    onChanged: (value) =>
                        setModalState(() => exampleMeaning = value),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
  if (values == null) return false;
  await store.setCardFontSizes(
    term: values[0],
    reading: values[1],
    meaning: values[2],
    example: values[3],
    exampleMeaning: values[4],
  );
  return true;
}

class _FontSizeSlider extends StatelessWidget {
  const _FontSizeSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
          Text(valueLabel,
              style: const TextStyle(color: sea, fontWeight: FontWeight.w800)),
        ]),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ]);
}

class _CircleStat extends StatelessWidget {
  const _CircleStat({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
      width: 62,
      height: 62,
      decoration:
          const BoxDecoration(color: Color(0xFFFFEAE6), shape: BoxShape.circle),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(value,
            style: const TextStyle(
                color: coral, fontSize: 20, fontWeight: FontWeight.w900)),
        Text(label, style: const TextStyle(color: Colors.black54, fontSize: 11))
      ]));
}

class _Metric extends StatelessWidget {
  const _Metric(
      {required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 30, fontWeight: FontWeight.w900))
          ])));
}

Future<Word?> _showWordEditor(BuildContext context, Word word) =>
    showModalBottomSheet<Word>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _WordEditorSheet(word: word),
    );

class _WordEditorSheet extends StatefulWidget {
  const _WordEditorSheet({required this.word});

  final Word word;

  @override
  State<_WordEditorSheet> createState() => _WordEditorSheetState();
}

class _WordEditorSheetState extends State<_WordEditorSheet> {
  late final TextEditingController term;
  late final TextEditingController reading;
  late final TextEditingController meaning;
  late final TextEditingController example;
  late final TextEditingController exampleMeaning;

  @override
  void initState() {
    super.initState();
    term = TextEditingController(text: widget.word.term);
    reading = TextEditingController(text: widget.word.reading);
    meaning = TextEditingController(text: widget.word.meaning);
    example = TextEditingController(text: widget.word.example);
    exampleMeaning = TextEditingController(text: widget.word.exampleMeaning);
  }

  @override
  void dispose() {
    term.dispose();
    reading.dispose();
    meaning.dispose();
    example.dispose();
    exampleMeaning.dispose();
    super.dispose();
  }

  void save() {
    if (term.text.trim().isEmpty) return;
    Navigator.pop(
      context,
      widget.word.copyWith(
        term: term.text.trim(),
        reading: reading.text.trim(),
        meaning: meaning.text.trim(),
        example: example.text.trim(),
        exampleMeaning: exampleMeaning.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Expanded(
                child: Text('단어 수정',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소')),
              const SizedBox(width: 4),
              FilledButton(onPressed: save, child: const Text('저장')),
            ]),
            const SizedBox(height: 16),
            TextField(
                key: const ValueKey('word-term'),
                controller: term,
                autofocus: true,
                decoration: const InputDecoration(labelText: '단어')),
            const SizedBox(height: 10),
            TextField(
                key: const ValueKey('word-reading'),
                controller: reading,
                decoration: const InputDecoration(labelText: '발음')),
            const SizedBox(height: 10),
            TextField(
                key: const ValueKey('word-meaning'),
                controller: meaning,
                decoration: const InputDecoration(labelText: '뜻')),
            const SizedBox(height: 10),
            TextField(
                key: const ValueKey('word-example'),
                controller: example,
                maxLines: 2,
                decoration: const InputDecoration(labelText: '예문')),
            const SizedBox(height: 10),
            TextField(
                key: const ValueKey('word-example-meaning'),
                controller: exampleMeaning,
                maxLines: 2,
                decoration: const InputDecoration(labelText: '예문 뜻')),
          ]),
        ),
      );
}

Future<String?> _askText(BuildContext context, String title, String initial) {
  return showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(title: title, initial: initial));
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
            key: const ValueKey('text-input-dialog'),
            controller: controller,
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('저장')),
        ],
      );
}

String _dDayText(int days) => days == 0
    ? 'D-day'
    : days > 0
        ? 'D-$days'
        : 'D+${days.abs()}';
