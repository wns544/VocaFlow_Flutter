import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class InAppBrowserPage extends StatefulWidget {
  const InAppBrowserPage({super.key, required this.uri, required this.title});

  final Uri uri;
  final String title;

  @override
  State<InAppBrowserPage> createState() => _InAppBrowserPageState();
}

class _InAppBrowserPageState extends State<InAppBrowserPage> {
  late final WebViewController _controller;
  var _loading = true;
  var _canGoBack = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
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
            final canGoBack = await _controller.canGoBack();
            if (mounted) {
              setState(() {
                _loading = false;
                _canGoBack = canGoBack;
              });
            }
          },
        ),
      )
      ..loadRequest(widget.uri);
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

  Future<void> _goBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
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
          canPop: !_canGoBack,
          onPopInvokedWithResult: (didPop, _) async {
            if (!didPop) await _goBack();
          },
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
      );
}
