const optionSelector = ".multi-select-option";

const hiddenInputValues = (root) =>
  Array.from(root.querySelectorAll('input[type="hidden"]'))
    .map((input) => input.value)
    .filter((value) => value && value.trim() !== "");

export const GaoNoteTagsMultiSelect = {
  mounted() {
    this.selected = new Set(hiddenInputValues(this.el));
    this.open = false;

    this._click = (event) => this.handleClick(event);
    this._input = (event) => this.handleInput(event);
    this._outsideClick = (event) => {
      if (!this.el.contains(event.target)) this.setOpen(false);
    };

    this.el.addEventListener("click", this._click);
    this.el.addEventListener("input", this._input);
    document.addEventListener("click", this._outsideClick);
  },

  updated() {
    this.selected = new Set(hiddenInputValues(this.el));
    this.setOpen(this.open);
  },

  destroyed() {
    this.el.removeEventListener("click", this._click);
    this.el.removeEventListener("input", this._input);
    document.removeEventListener("click", this._outsideClick);
  },

  handleClick(event) {
    const clear = event.target.closest(".multi-select-clear-all");
    if (clear && this.el.contains(clear)) {
      event.preventDefault();
      event.stopPropagation();
      this.selected.clear();
      this.pushSelected();
      return;
    }

    const remove = event.target.closest(".multi-select-tag-remove");
    if (remove && this.el.contains(remove)) {
      event.preventDefault();
      event.stopPropagation();
      const tag = remove.closest(".multi-select-tag");
      const value = tag?.querySelector(".multi-select-tag-text")?.textContent?.trim();
      if (value) {
        this.selected.delete(value);
        this.pushSelected();
      }
      return;
    }

    const option = event.target.closest(optionSelector);
    if (option && this.el.contains(option)) {
      event.preventDefault();
      event.stopPropagation();
      this.toggleOption(option);
      return;
    }

    const trigger = event.target.closest(".multi-select-trigger");
    if (trigger && this.el.contains(trigger)) {
      event.preventDefault();
      event.stopPropagation();
      this.setOpen(!this.open);
    }
  },

  handleInput(event) {
    if (!event.target.matches(".multi-select-search-input")) return;

    const query = event.target.value.trim().toLowerCase();
    this.el.querySelectorAll(optionSelector).forEach((option) => {
      const label = option.textContent.trim().toLowerCase();
      option.hidden = query !== "" && !label.includes(query);
    });
  },

  toggleOption(option) {
    if (option.classList.contains("multi-select-option-disabled")) return;

    const value = option.dataset.value;
    if (!value) return;

    if (this.selected.has(value)) {
      this.selected.delete(value);
    } else {
      this.selected.add(value);
    }

    this.open = true;
    this.pushSelected();
  },

  setOpen(open) {
    this.open = open;
    this.el.classList.toggle("multi-select-open", open);
    this.el
      .querySelector(".multi-select-trigger")
      ?.setAttribute("aria-expanded", String(open));
  },

  pushSelected() {
    this.pushEvent("set_tags", { tags: Array.from(this.selected) });
  },
};
