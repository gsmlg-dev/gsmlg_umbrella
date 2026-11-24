export function mountRepoTabs(root) {
  const tablist = root?.querySelector('[role="tablist"]');
  if (!tablist) return;

  const tabs = [...tablist.querySelectorAll('[role="tab"]')];
  const panels = tabs.map((tab) =>
    root.ownerDocument.getElementById(tab.getAttribute("aria-controls"))
  );

  function selectTab(index, focus = false) {
    tabs.forEach((tab, tabIndex) => {
      const selected = tabIndex === index;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      panels[tabIndex].hidden = !selected;
    });

    const tab = tabs[index];
    if (focus) tab.focus({ preventScroll: true });

    const strip = tablist.getBoundingClientRect();
    const button = tab.getBoundingClientRect();
    if (button.left < strip.left) {
      tablist.scrollLeft += button.left - strip.left;
    } else if (button.right > strip.right) {
      tablist.scrollLeft += button.right - strip.right;
    }
  }

  tablist.addEventListener("click", (event) => {
    const index = tabs.indexOf(event.target.closest('[role="tab"]'));
    if (index !== -1) selectTab(index);
  });

  tablist.addEventListener("keydown", (event) => {
    const index = tabs.indexOf(event.target.closest('[role="tab"]'));
    if (index === -1) return;

    let next;
    switch (event.key) {
      case "ArrowLeft":
        next = (index + tabs.length - 1) % tabs.length;
        break;
      case "ArrowRight":
        next = (index + 1) % tabs.length;
        break;
      case "Home":
        next = 0;
        break;
      case "End":
        next = tabs.length - 1;
        break;
      default:
        return;
    }

    event.preventDefault();
    selectTab(next, true);
  });
}
