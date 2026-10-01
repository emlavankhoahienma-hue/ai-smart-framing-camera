/**
 * Align Camera - Core Interactive Scripts
 * Handles FAQ accordion toggles, clipboard operations with visual feedback,
 * active scroll spying on navigation pills, and interactive camera simulations.
 * Zero emojis. Pure semantic engineering.
 */

document.addEventListener('DOMContentLoaded', () => {
  initNavigationSpy();
  initFaqAccordion();
  initChecksumCopy();
  initStandbyDemo();
  initViewfinderDemo();
});

/**
 * 1. Navigation Active State & Smooth Scroll
 */
function initNavigationSpy() {
  const navLinks = document.querySelectorAll('.nav-pill-link');
  const sections = document.querySelectorAll('section[id]');

  if (!sections.length || !navLinks.length) return;

  const observerOptions = {
    root: null,
    rootMargin: '-20% 0px -60% 0px',
    threshold: 0
  };

  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        const currentId = entry.target.getAttribute('id');
        navLinks.forEach((link) => {
          if (link.getAttribute('href') === `#${currentId}`) {
            link.classList.add('active');
          } else {
            link.classList.remove('active');
          }
        });
      }
    });
  }, observerOptions);

  sections.forEach((section) => observer.observe(section));
}

/**
 * 2. FAQ Accordion Toggle System
 */
function initFaqAccordion() {
  const accordionHeaders = document.querySelectorAll('.accordion-header');

  accordionHeaders.forEach((header) => {
    header.addEventListener('click', () => {
      const parentItem = header.closest('.accordion-item');
      if (!parentItem) return;

      const isOpen = parentItem.classList.contains('open');

      // Close all other accordions for clean single-focus reading
      document.querySelectorAll('.accordion-item').forEach((item) => {
        if (item !== parentItem) {
          item.classList.remove('open');
          const itemHeader = item.querySelector('.accordion-header');
          if (itemHeader) {
            itemHeader.setAttribute('aria-expanded', 'false');
          }
        }
      });

      // Toggle current accordion
      if (isOpen) {
        parentItem.classList.remove('open');
        header.setAttribute('aria-expanded', 'false');
      } else {
        parentItem.classList.add('open');
        header.setAttribute('aria-expanded', 'true');
      }
    });
  });
}

/**
 * 3. SHA-256 Checksum Clipboard Copy with Visual Feedback
 */
function initChecksumCopy() {
  const copyButtons = document.querySelectorAll('.copy-hash-btn');

  copyButtons.forEach((button) => {
    button.addEventListener('click', async () => {
      const hashValue = button.getAttribute('data-hash') || '12A9C9FF9049C8D6E6BBB2EDD8CFE7E1CC490E2AAE94AFF846E0F941DD2BCD62';
      const labelSpan = button.querySelector('.copy-label');
      const iconContainer = button.querySelector('.copy-icon');

      const originalText = labelSpan ? labelSpan.textContent : '';

      try {
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(hashValue);
        } else {
          // Fallback for non-https or older browser contexts
          const textArea = document.createElement('textarea');
          textArea.value = hashValue;
          textArea.style.position = 'fixed';
          textArea.style.left = '-999999px';
          textArea.style.top = '-999999px';
          document.body.appendChild(textArea);
          textArea.focus();
          textArea.select();
          document.execCommand('copy');
          textArea.remove();
        }

        // Show Success Feedback
        if (labelSpan) {
          labelSpan.textContent = 'Đã sao chép mã băm';
        }
        button.classList.add('border-[#10B981]', 'text-[#10B981]');
        if (iconContainer) {
          iconContainer.innerHTML = `
            <svg class="w-4 h-4 text-[#10B981]" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
            </svg>
          `;
        }

        // Reset after 2.5 seconds
        setTimeout(() => {
          if (labelSpan) {
            labelSpan.textContent = originalText;
          }
          button.classList.remove('border-[#10B981]', 'text-[#10B981]');
          if (iconContainer) {
            iconContainer.innerHTML = `
              <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="1.75" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/>
              </svg>
            `;
          }
        }, 2500);

      } catch (err) {
        console.error('Không thể sao chép văn bản:', err);
      }
    });
  });
}

/**
 * 4. Hibernation Standby Simulation (Dark / Light Canvas Switcher)
 */
function initStandbyDemo() {
  const toggleBtn = document.getElementById('toggleStandbyThemeBtn');
  const canvas = document.getElementById('standbyCanvas');
  const modeText = document.getElementById('standbyModeText');
  const logoPath = document.getElementById('standbyLogoPath');

  if (!toggleBtn || !canvas) return;

  let isDark = true;

  toggleBtn.addEventListener('click', () => {
    isDark = !isDark;
    if (isDark) {
      canvas.classList.remove('standby-canvas-light');
      canvas.classList.add('standby-canvas-dark');
      toggleBtn.textContent = 'Chuyển sang Nền Trắng';
      if (modeText) modeText.textContent = 'Trạng thái: Nền Đen Tối Giản (OLED Pure Black)';
      if (logoPath) logoPath.setAttribute('stroke', '#F2F4F8');
    } else {
      canvas.classList.remove('standby-canvas-dark');
      canvas.classList.add('standby-canvas-light');
      toggleBtn.textContent = 'Chuyển sang Nền Đen';
      if (modeText) modeText.textContent = 'Trạng thái: Nền Trắng Tinh Khiết (Studio White)';
      if (logoPath) logoPath.setAttribute('stroke', '#090A0D');
    }
  });
}

/**
 * 5. Interactive Viewfinder HUD Filters
 */
function initViewfinderDemo() {
  const gridToggle = document.getElementById('btnToggleGrid');
  const gridOverlay = document.getElementById('viewfinderGrid');
  const targetLabel = document.getElementById('hudTargetType');
  const confLabel = document.getElementById('hudConfScore');

  if (gridToggle && gridOverlay) {
    gridToggle.addEventListener('click', () => {
      const isHidden = gridOverlay.classList.contains('opacity-0');
      if (isHidden) {
        gridOverlay.classList.remove('opacity-0');
        gridToggle.classList.add('border-[#3B82F6]', 'text-[#3B82F6]');
      } else {
        gridOverlay.classList.add('opacity-0');
        gridToggle.classList.remove('border-[#3B82F6]', 'text-[#3B82F6]');
      }
    });
  }

  // Periodic simulated target tracking coordinates & latency fluctuation
  const coordsLabel = document.getElementById('hudCoords');
  const latencyLabel = document.getElementById('hudLatency');

  if (coordsLabel && latencyLabel) {
    setInterval(() => {
      const lat = (1.4 + Math.random() * 2.2).toFixed(1);
      latencyLabel.textContent = `ANE ${lat}ms`;

      const x = (0.45 + (Math.random() - 0.5) * 0.06).toFixed(3);
      const y = (0.50 + (Math.random() - 0.5) * 0.04).toFixed(3);
      coordsLabel.textContent = `NORM [${x}, ${y}]`;
    }, 1800);
  }
}
