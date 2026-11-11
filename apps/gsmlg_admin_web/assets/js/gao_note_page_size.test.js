import assert from "node:assert/strict";
import { afterEach, describe, test } from "node:test";

import { readGaoNotePageSize, saveGaoNotePageSize } from './gao_note_page_size.js';

const storageKey = 'gsmlg:gao-note:page-size';
const originalStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');

afterEach(() => {
  if (originalStorage) {
    Object.defineProperty(globalThis, 'localStorage', originalStorage);
  } else {
    delete globalThis.localStorage;
  }
});

describe('GaoNote page-size preference', () => {
  for (const pageSize of [10, 25, 50, 100]) {
    test(`persists and reads page size ${pageSize}`, () => {
      const values = installStorage();

      saveGaoNotePageSize(pageSize);

      assert.strictEqual(values.get(storageKey), String(pageSize));
      assert.strictEqual(readGaoNotePageSize(), pageSize);
    });
  }

  test('accepts a valid choice received as a string', () => {
    installStorage();
    saveGaoNotePageSize('50');
    assert.strictEqual(readGaoNotePageSize(), 50);
  });

  test('returns null for missing, malformed, or unsupported storage values', () => {
    const values = installStorage();
    assert.strictEqual(readGaoNotePageSize(), null);

    for (const value of ['', 'null', 'abc', '25.0', '025', ' 25 ', '20', '200', '-10']) {
      values.set(storageKey, value);
      assert.strictEqual(readGaoNotePageSize(), null);
    }
  });

  test('invalid selections leave the saved preference intact', () => {
    const values = installStorage();
    saveGaoNotePageSize(25);

    for (const value of [null, undefined, false, [], {}, 0, 20, 25.5, '25.0', ' 25 ']) {
      saveGaoNotePageSize(value);
      assert.strictEqual(values.get(storageKey), '25');
    }
  });

  test('handles unavailable storage including a blocked storage property', () => {
    delete globalThis.localStorage;
    assert.strictEqual(readGaoNotePageSize(), null);
    assert.doesNotThrow(() => saveGaoNotePageSize(25));

    Object.defineProperty(globalThis, 'localStorage', {
      configurable: true,
      get() { throw new Error('Storage blocked'); },
    });

    assert.strictEqual(readGaoNotePageSize(), null);
    assert.doesNotThrow(() => saveGaoNotePageSize(25));
  });

  test('handles failed reads and writes without interrupting the page', () => {
    Object.defineProperty(globalThis, 'localStorage', {
      configurable: true,
      value: {
        getItem() { throw new Error('Storage read failed'); },
        setItem() { throw new Error('Quota exceeded'); },
      },
    });

    assert.strictEqual(readGaoNotePageSize(), null);
    assert.doesNotThrow(() => saveGaoNotePageSize(100));
  });

  test('reads the latest preference on each call', () => {
    installStorage();
    saveGaoNotePageSize(10);
    assert.strictEqual(readGaoNotePageSize(), 10);
    saveGaoNotePageSize(100);
    assert.strictEqual(readGaoNotePageSize(), 100);
  });
});

function installStorage() {
  const values = new Map();
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: {
      getItem: (key) => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, value),
    },
  });
  return values;
}
