/**
 * Align Camera - Core Interactive Scripts (MWM Architecture)
 * Handles FAQ accordion toggles, clipboard operations with visual feedback,
 * and active scroll tracking on navigation pills.
 * Zero emojis. Pure semantic engineering.
 */

document.addEventListener('DOMContentLoaded', () => {
  initNavigationPills();
  initFaqAccordion();
  initChecksumCopy();
});

/**
 * 1. Navigation Pills Active State & Smooth Scroll Tracking
 */
function initNavigationPills() {
  const navLinks = document.querySelectorAll('.mwm-pill');
  const sections = document.querySelectorAll('section[id]');

  if (!sections.length || !navLinks.length) return;

  const observerOptions = {
    root: null,
    rootMargin: '-20% 0px -50% 0px',
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
 * 2. FAQ Accordion System
 */
function initFaqAccordion() {
  const accordionHeaders = document.querySelectorAll('.mwm-accordion-header');

  accordionHeaders.forEach((header) => {
    header.addEventListener('click', () => {
      const parentItem = header.closest('.mwm-accordion-item');
      if (!parentItem) return;

      const isOpen = parentItem.classList.contains('open');

      // Close all other accordions for focused reading
      document.querySelectorAll('.mwm-accordion-item').forEach((item) => {
        if (item !== parentItem) {
          item.classList.remove('open');
          const itemHeader = item.querySelector('.mwm-accordion-header');
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
