import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

typedef BrowserNavigationButtonHandler = Future<bool> Function(
    String direction);
BrowserNavigationButtonHandler? activeBrowserNavigationButtonHandler;

class InAppBrowserPage extends StatefulWidget {
  const InAppBrowserPage({super.key, required this.uri, required this.title});

  final Uri uri;
  final String title;

  @override
  State<InAppBrowserPage> createState() => _InAppBrowserPageState();
}

class _InAppBrowserPageState extends State<InAppBrowserPage> {
  late final WebViewController _controller;
  final FocusNode _focusNode = FocusNode(debugLabel: 'in-app-browser');
  var _loading = true;
  var _canGoBack = false;
  var _canGoForward = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    activeBrowserNavigationButtonHandler = _handleNavigationButton;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _loading = true;
                _errorMessage = null;
              });
            }
          },
          onPageFinished: (_) async {
            await _applyAdFilter();
            await _refreshHistoryState();
            if (mounted) {
              setState(() {
                _loading = false;
              });
            }
          },
        ),
      )
      ..loadRequest(widget.uri);
  }

  @override
  void dispose() {
    if (identical(
        activeBrowserNavigationButtonHandler, _handleNavigationButton)) {
      activeBrowserNavigationButtonHandler = null;
    }
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _applyAdFilter() async {
    const selectors = [
      'ins.adsbygoogle',
      '.adsbygoogle',
      '[data-ad-client]',
      '[data-ad-slot]',
      '[id^="google_ads"]',
      '[id*="google_ads_"]',
      'iframe[src*="doubleclick.net"]',
      'iframe[src*="googlesyndication.com"]',
      'iframe[src*="googleadservices.com"]',
      '.google-auto-placed',
      '.ad-banner',
      '.ad-container',
      '.ad-wrapper',
      '.advertisement',
      '.advertising',
    ];
    final selectorList = selectors.map((selector) => "'$selector'").join(',');
    final script = '''
(() => {
  const selectors = [$selectorList];
  const hideAds = () => {
    let hidden = 0;
    for (const selector of selectors) {
      document.querySelectorAll(selector).forEach((element) => {
        if (element.dataset.vocaflowAdHidden === 'true') return;
        element.dataset.vocaflowAdHidden = 'true';
        element.style.setProperty('display', 'none', 'important');
        element.style.setProperty('visibility', 'hidden', 'important');
        element.style.setProperty('height', '0', 'important');
        element.style.setProperty('min-height', '0', 'important');
        element.style.setProperty('margin', '0', 'important');
        element.style.setProperty('padding', '0', 'important');
        hidden += 1;
      });
    }
    return hidden;
  };
  const hidden = hideAds();
  if (!window.__vocaflowAdFilterInstalled) {
    window.__vocaflowAdFilterInstalled = true;
    new MutationObserver(hideAds).observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
  }
  return String(hidden);
})()
''';
    try {
      await _controller.runJavaScriptReturningResult(script);
    } catch (_) {
      // A page may block script injection; the browser itself must still work.
    }
  }

  Future<void> _refreshHistoryState() async {
    final canGoBack = await _controller.canGoBack();
    final canGoForward = await _controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;
    });
  }

  Future<void> _goBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      await _refreshHistoryState();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _goForward() async {
    if (await _controller.canGoForward()) {
      await _controller.goForward();
      await _refreshHistoryState();
    }
  }

  Future<bool> _handleNavigationButton(String direction) async {
    if (direction == 'back') {
      await _goBack();
      return true;
    }
    if (direction == 'forward') {
      await _goForward();
      return true;
    }
    return false;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.browserBack ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      _goBack();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.browserForward ||
        (event.logicalKey == LogicalKeyboardKey.arrowRight &&
            HardwareKeyboard.instance.isAltPressed)) {
      _goForward();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      _goBack();
    } else if (event.buttons == kForwardMouseButton) {
      _goForward();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: '뒤로',
              onPressed:
                  _canGoBack ? _goBack : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              tooltip: '앞으로',
              onPressed: _canGoForward ? _goForward : null,
              icon: const Icon(Icons.arrow_forward),
            ),
            IconButton(
              tooltip: '새로고침',
              onPressed: _controller.reload,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: _loading
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(2),
                  child: LinearProgressIndicator(),
                )
              : null,
        ),
        body: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (!didPop) await _goBack();
          },
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: Listener(
              onPointerDown: _handlePointerDown,
              child: Stack(
                children: [
                  WebViewWidget(controller: _controller),
                  if (_errorMessage != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.public_off_outlined, size: 40),
                            const SizedBox(height: 12),
                            Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _controller.reload,
                              icon: const Icon(Icons.refresh),
                              label: const Text('다시 시도'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}
