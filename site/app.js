"use strict";

// Panels keep their place in the grid. Only visibility and focusability change.
function showPanel(panel, visible) {
  panel.classList.toggle('is-active', visible);
  panel.inert = !visible;
  panel.toggleAttribute('inert', !visible);
  panel.setAttribute('aria-hidden', String(!visible));
}

function bindTabKeys(list, tabs, activate) {
  tabs.forEach((tab, index) => {
    tab.addEventListener('keydown', event => {
      if (event.altKey || event.ctrlKey || event.metaKey) return;
      const vertical = list.getAttribute('aria-orientation') === 'vertical';
      let next;
      if (event.key === (vertical ? 'ArrowUp' : 'ArrowLeft')) next = (index - 1 + tabs.length) % tabs.length;
      if (event.key === (vertical ? 'ArrowDown' : 'ArrowRight')) next = (index + 1) % tabs.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = tabs.length - 1;
      if (next === undefined) return;
      event.preventDefault();
      activate(tabs[next]);
      tabs[next].focus({ preventScroll: true });
    });
  });
}

// Each browser remembers the selected feature within every category.
document.querySelectorAll('[data-feature-browser]').forEach(browser => {
  const categories = browser.querySelector('.feature-categories');
  if (!categories) return;
  const tabs = [...categories.querySelectorAll('[role="tab"]')];
  const groups = [...browser.querySelectorAll('.feature-group')];
  const descriptions = [...browser.querySelectorAll('.feature-description')];
  const groupById = new Map(groups.map(group => [group.id, group]));
  const descriptionById = new Map(descriptions.map(description => [description.id, description]));
  const selectedByGroup = new Map();
  if (!tabs.length || !descriptions.length || tabs.some(tab => !groupById.has(tab.getAttribute('aria-controls')))) return;
  if (groups.some(group => {
    const buttons = [...group.querySelectorAll('.feature-button')];
    if (!buttons.length || buttons.some(button => !descriptionById.has(button.getAttribute('aria-controls')))) return true;
    selectedByGroup.set(group, buttons.find(button => button.getAttribute('aria-pressed') === 'true') || buttons[0]);
    return false;
  })) return;

  let activeGroup;
  const selectFeature = (group, button) => {
    selectedByGroup.set(group, button);
    group.querySelectorAll('.feature-button').forEach(item => {
      item.setAttribute('aria-pressed', String(item === button));
    });
    if (group !== activeGroup) return;
    const selectedDescription = descriptionById.get(button.getAttribute('aria-controls'));
    descriptions.forEach(description => showPanel(description, description === selectedDescription));
  };
  const activateCategory = tab => {
    activeGroup = groupById.get(tab.getAttribute('aria-controls'));
    tabs.forEach(item => {
      const selected = item === tab;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
    });
    groups.forEach(group => showPanel(group, group === activeGroup));
    selectFeature(activeGroup, selectedByGroup.get(activeGroup));
  };

  groups.forEach(group => {
    group.querySelectorAll('.feature-button').forEach(button => {
      button.addEventListener('click', () => selectFeature(group, button));
    });
    selectFeature(group, selectedByGroup.get(group));
  });
  tabs.forEach(tab => tab.addEventListener('click', () => activateCategory(tab)));
  bindTabKeys(categories, tabs, activateCategory);
  activateCategory(tabs.find(tab => tab.getAttribute('aria-selected') === 'true') || tabs[0]);
  browser.classList.add('is-enhanced');
});

// Connection and FAQ panels use the same stable grid contract.
document.querySelectorAll('[role="tablist"]').forEach(list => {
  if (list.closest('[data-feature-browser]')) return;
  const tabs = [...list.querySelectorAll('[role="tab"]')];
  const panels = tabs.map(tab => document.getElementById(tab.getAttribute('aria-controls')));
  if (!tabs.length || panels.some(panel => !panel)) return;
  const activate = tab => {
    tabs.forEach((item, index) => {
      const selected = item === tab;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
      showPanel(panels[index], selected);
    });
    if (list.classList.contains('connection-options')) {
      const visual = document.querySelector('.connection-visual');
      if (visual) visual.dataset.mode = tab.id.replace('connect-', '');
    }
  };
  tabs.forEach(tab => tab.addEventListener('click', () => activate(tab)));
  bindTabKeys(list, tabs, activate);
  activate(tabs.find(tab => tab.getAttribute('aria-selected') === 'true') || tabs[0]);
});

const menu = document.querySelector('.menu-toggle');
const navLinks = document.querySelector('.nav-links');
if (menu && navLinks) {
  const closeMenu = () => {
    menu.setAttribute('aria-expanded', 'false');
    menu.setAttribute('aria-label', '打开导航');
    navLinks.classList.remove('is-open');
  };
  menu.addEventListener('click', () => {
    const expanded = menu.getAttribute('aria-expanded') !== 'true';
    menu.setAttribute('aria-expanded', String(expanded));
    menu.setAttribute('aria-label', expanded ? '关闭导航' : '打开导航');
    navLinks.classList.toggle('is-open', expanded);
  });
  navLinks.addEventListener('click', event => {
    if (event.target.closest('a')) closeMenu();
  });
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape' || menu.getAttribute('aria-expanded') !== 'true') return;
    event.preventDefault();
    closeMenu();
    menu.focus({ preventScroll: true });
  });
  document.addEventListener('click', event => {
    if (!event.target.closest('.nav')) closeMenu();
  });
  matchMedia('(min-width: 760px)').addEventListener('change', closeMenu);
}

const copyButton = document.querySelector('.copy-contact');
const copyStatus = document.querySelector('.copy-status');
if (copyButton && copyStatus) {
  let copyTimer;
  copyButton.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(copyButton.dataset.copy);
      copyStatus.textContent = '已复制';
    } catch {
      copyStatus.textContent = '请长按号码复制';
    }
    clearTimeout(copyTimer);
    copyTimer = setTimeout(() => { copyStatus.textContent = ''; }, 4000);
  });
}

const year = document.getElementById('year');
if (year) year.textContent = new Date().getFullYear();
document.documentElement.classList.add('has-js');

// Decorative media can fade in once; content never moves with scroll position.
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const revealElements = [...document.querySelectorAll('.reveal')];
let revealObserver;
const revealAll = () => {
  revealElements.forEach(element => element.classList.add('is-visible'));
  revealObserver?.disconnect();
};
if (!reducedMotion.matches && 'IntersectionObserver' in window) {
  revealObserver = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-visible');
      revealObserver.unobserve(entry.target);
    });
  }, { threshold: .05 });
  revealElements.forEach(element => revealObserver.observe(element));
} else {
  revealAll();
}
reducedMotion.addEventListener('change', event => {
  if (event.matches) revealAll();
});
