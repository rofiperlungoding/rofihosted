// Theme persistence + drawer toggle.
(function () {
  const KEY = 'rofi.theme';
  const root = document.documentElement;

  function setTheme(t, persist) {
    root.classList.add('t');
    root.setAttribute('data-theme', t);
    if (persist) {
      try { localStorage.setItem(KEY, t); } catch (e) {}
    }
    setTimeout(function () { root.classList.remove('t'); }, 250);
  }
  function toggle() {
    const cur = root.getAttribute('data-theme') || 'dark';
    setTheme(cur === 'dark' ? 'light' : 'dark', true);
  }

  function initToggle() {
    document.querySelectorAll('[data-action="toggle-theme"]').forEach(function (b) {
      b.addEventListener('click', toggle);
    });
  }

  function initDrawer() {
    const sidebar = document.querySelector('[data-drawer]');
    const btn = document.querySelector('[data-action="toggle-drawer"]');
    const backdrop = document.querySelector('[data-drawer-backdrop]');
    if (!sidebar || !btn) return;

    function open() {
      sidebar.classList.add('open');
      if (backdrop) backdrop.classList.add('show');
      document.body.style.overflow = 'hidden';
    }
    function close() {
      sidebar.classList.remove('open');
      if (backdrop) backdrop.classList.remove('show');
      document.body.style.overflow = '';
    }
    btn.addEventListener('click', function () {
      sidebar.classList.contains('open') ? close() : open();
    });
    if (backdrop) backdrop.addEventListener('click', close);
    sidebar.querySelectorAll('a').forEach(function (a) { a.addEventListener('click', close); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') close(); });
    let last = window.innerWidth;
    window.addEventListener('resize', function () {
      if (window.innerWidth >= 1024 && last < 1024) close();
      last = window.innerWidth;
    });
  }

  function init() {
    initToggle();
    initDrawer();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
