{{flutter_js}}
{{flutter_build_config}}

// Flutter's generated service worker can keep an older application shell
// controlling this origin even after a Hosting release. VocaFlow already uses
// Firebase as its durable store, so prefer ordinary HTTP cache validation and
// retire only Flutter's application-shell workers. Browser data such as
// localStorage, IndexedDB, login state, and learning progress is untouched.
(async () => {
  if ('serviceWorker' in navigator) {
    try {
      const registrations = await navigator.serviceWorker.getRegistrations();
      await Promise.all(
        registrations
          .filter((registration) =>
            registration.active?.scriptURL.includes('flutter_service_worker.js') ||
            registration.waiting?.scriptURL.includes('flutter_service_worker.js') ||
            registration.installing?.scriptURL.includes('flutter_service_worker.js'))
          .map((registration) => registration.unregister()),
      );
    } catch (error) {
      console.warn('Could not retire the old Flutter service worker.', error);
    }
  }

  _flutter.loader.load();
})();
