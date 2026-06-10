// warroom2/static/js/copy_modal.js — fallback "Copy buffer" modal for OSC 52 misses.
(function () {
  'use strict';

  function showCopyModal(text) {
    var modal = document.getElementById('copy-modal');
    var ta = document.getElementById('copy-modal-text');
    if (!modal || !ta) return;
    ta.value = text || '';
    modal.removeAttribute('hidden');
    setTimeout(function () {
      ta.focus();
      ta.select();
    }, 10);
  }

  function hideCopyModal() {
    var modal = document.getElementById('copy-modal');
    if (modal) modal.setAttribute('hidden', '');
  }

  function bind() {
    var closeBtn = document.getElementById('copy-modal-close');
    if (closeBtn) closeBtn.addEventListener('click', hideCopyModal);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') {
        var modal = document.getElementById('copy-modal');
        if (modal && !modal.hasAttribute('hidden')) hideCopyModal();
      }
    });
    // Click on backdrop closes
    var modal = document.getElementById('copy-modal');
    if (modal) {
      modal.addEventListener('click', function (e) {
        if (e.target === modal) hideCopyModal();
      });
    }
  }

  window.showCopyModal = showCopyModal;
  window.hideCopyModal = hideCopyModal;
  window.WRCopyModal = { show: showCopyModal, hide: hideCopyModal, bind: bind };
})();
