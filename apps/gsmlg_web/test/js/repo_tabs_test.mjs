import assert from "node:assert/strict";
import { test } from "node:test";
import { mountRepoTabs } from "../../assets/js/repo_tabs.js";

function repoTabs() {
  const tablist = new EventTarget();
  const panels = [false, true, true].map((hidden) => ({ hidden }));
  const tabs = panels.map((panel, index) => {
    const attrs = new Map([
      ["aria-controls", `panel-${index}`],
      ["aria-selected", String(!panel.hidden)],
    ]);
    return {
      tabIndex: panel.hidden ? -1 : 0,
      getAttribute: (name) => attrs.get(name),
      setAttribute: (name, value) => attrs.set(name, value),
      getBoundingClientRect: () => ({
        left: index * 100 - tablist.scrollLeft,
        right: (index + 1) * 100 - tablist.scrollLeft,
      }),
      focus(options) {
        this.focusOptions = options;
      },
    };
  });
  Object.assign(tablist, {
    querySelectorAll: () => tabs,
    getBoundingClientRect: () => ({ left: 0, right: 200 }),
    scrollLeft: 0,
  });
  mountRepoTabs({
    querySelector: () => tablist,
    ownerDocument: {
      getElementById: (id) => panels[Number(id.slice("panel-".length))],
    },
  });
  return { tablist, tabs, panels };
}

function sendInput(tablist, tab, type, key) {
  const event = new Event(type, { cancelable: true });
  Object.defineProperties(event, {
    target: { value: { closest: () => tab } },
    key: { value: key },
  });
  tablist.dispatchEvent(event);
  return event;
}

test("clicking a tab selects its repository panel and transfers the tab stop", () => {
  const { tablist, tabs, panels } = repoTabs();
  tablist.scrollLeft = 100;
  sendInput(tablist, tabs[2], "click");

  assert.deepEqual(panels.map((panel) => panel.hidden), [true, true, false]);
  assert.deepEqual(tabs.map((tab) => tab.getAttribute("aria-selected")), ["false", "false", "true"]);
  assert.deepEqual(tabs.map((tab) => tab.tabIndex), [-1, -1, 0]);
  assert.equal(tablist.scrollLeft, 100);
});

test("keyboard navigation wraps and scrolls only the tab strip to the selected group", () => {
  const { tablist, tabs, panels } = repoTabs();
  const arrow = sendInput(tablist, tabs[0], "keydown", "ArrowLeft");

  assert.equal(arrow.defaultPrevented, true);
  assert.equal(panels[2].hidden, false);
  assert.deepEqual(tabs[2].focusOptions, { preventScroll: true });
  assert.equal(tablist.scrollLeft, 100);

  sendInput(tablist, tabs[2], "keydown", "Home");
  assert.deepEqual(panels.map((panel) => panel.hidden), [false, true, true]);
  assert.deepEqual(tabs[0].focusOptions, { preventScroll: true });
  assert.equal(tablist.scrollLeft, 0);

  const vertical = sendInput(tablist, tabs[0], "keydown", "ArrowDown");
  assert.equal(vertical.defaultPrevented, false);
  assert.equal(panels[0].hidden, false);
});
