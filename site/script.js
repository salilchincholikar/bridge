'use strict';
const tabs = [...document.querySelectorAll('[role="tab"]')];
const panels = [...document.querySelectorAll('[role="tabpanel"]')];
const status = document.querySelector('.copy-status');
const copy = document.querySelector('.copy-button');
function activate(tab, focus = false) {
  tabs.forEach(item => {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
  });
  panels.forEach(panel => { panel.hidden = panel.id !== tab.getAttribute('aria-controls'); });
  status.textContent = tab.dataset.mode === 'demo' ? 'Demo uses fictional data.' : 'Uses your configured AWS profile.';
  if (focus) tab.focus();
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => activate(tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) { event.preventDefault(); activate(tabs[next], true); }
  });
});
copy.addEventListener('click', async () => {
  const code = panels.find(panel => !panel.hidden).querySelector('code');
  try {
    await navigator.clipboard.writeText(code.textContent.trim());
    status.textContent = 'Commands copied.';
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(code); selection.removeAllRanges(); selection.addRange(range);
    status.textContent = 'Commands selected. Press ⌘C or Ctrl+C.';
  }
});
