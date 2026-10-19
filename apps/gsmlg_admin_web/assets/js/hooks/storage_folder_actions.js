const StorageFolderActions = {
  mounted() {
    this.onFolderDialogClose = (event) => {
      const dialog = event.target;
      if (!dialog.matches("dialog[data-folder-action-trigger]")) return;

      const trigger = this.el.ownerDocument.getElementById(dialog.dataset.folderActionTrigger);
      const target = trigger && this.el.contains(trigger)
        ? trigger
        : this.el.querySelector("#storage-root-folder");
      target?.focus();
    };
    this.el.addEventListener("close", this.onFolderDialogClose, true);
  },

  destroyed() {
    this.el.removeEventListener("close", this.onFolderDialogClose, true);
  },
};

export default StorageFolderActions;
