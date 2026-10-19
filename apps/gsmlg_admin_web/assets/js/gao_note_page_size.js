const storageKey = 'gsmlg:gao-note:page-size';
const pageSizes = [10, 25, 50, 100];

function normalizePageSize(value) {
  return pageSizes.find((size) => value === size || value === String(size)) ?? null;
}

export function readGaoNotePageSize() {
  try {
    return normalizePageSize(localStorage.getItem(storageKey));
  } catch {
    return null;
  }
}

export function saveGaoNotePageSize(value) {
  const pageSize = normalizePageSize(value);
  if (pageSize === null) return;

  try {
    localStorage.setItem(storageKey, String(pageSize));
  } catch {
    // Browsing remains available when storage is disabled or full.
  }
}
