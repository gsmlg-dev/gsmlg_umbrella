const IndeterminateCheckbox = {
  mounted() {
    this.syncIndeterminate();
  },

  updated() {
    this.syncIndeterminate();
  },

  syncIndeterminate() {
    this.el.indeterminate = this.el.dataset.state === "mixed";
  },
};

export default IndeterminateCheckbox;
