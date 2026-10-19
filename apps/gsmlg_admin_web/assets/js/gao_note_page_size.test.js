import { afterEach, describe, expect, test } from 'bun:test';

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
  test.each([10, 25, 50, 100])('persists and reads page size %i', (pageSize) => {
    const values = installStorage();

    saveGaoNotePageSize(pageSize);

    expect(values.get(storageKey)).toBe(String(pageSize));
    expect(readGaoNotePageSize()).toBe(pageSize);
  });

  test('accepts a valid choice received as a string', () => {
    installStorage();
    saveGaoNotePageSize('50');
    expect(readGaoNotePageSize()).toBe(50);
  });

  test('returns null for missing, malformed, or unsupported storage values', () => {
    const values = installStorage();
    expect(readGaoNotePageSize()).toBeNull();

    for (const value of ['', 'null', 'abc', '25.0', '025', ' 25 ', '20', '200', '-10']) {
      values.set(storageKey, value);
      expect(readGaoNotePageSize()).toBeNull();
    }
  });

  test('invalid selections leave the saved preference intact', () => {
    const values = installStorage();
    saveGaoNotePageSize(25);

    for (const value of [null, undefined, false, [], {}, 0, 20, 25.5, '25.0', ' 25 ']) {
      saveGaoNotePageSize(value);
      expect(values.get(storageKey)).toBe('25');
    }
  });

  test('handles unavailable storage including a blocked storage property', () => {
    delete globalThis.localStorage;
    expect(readGaoNotePageSize()).toBeNull();
    expect(() => saveGaoNotePageSize(25)).not.toThrow();

    Object.defineProperty(globalThis, 'localStorage', {
      configurable: true,
      get() { throw new Error('Storage blocked'); },
    });

    expect(readGaoNotePageSize()).toBeNull();
    expect(() => saveGaoNotePageSize(25)).not.toThrow();
  });

  test('handles failed reads and writes without interrupting the page', () => {
    Object.defineProperty(globalThis, 'localStorage', {
      configurable: true,
      value: {
        getItem() { throw new Error('Storage read failed'); },
        setItem() { throw new Error('Quota exceeded'); },
      },
    });

    expect(readGaoNotePageSize()).toBeNull();
    expect(() => saveGaoNotePageSize(100)).not.toThrow();
  });

  test('reads the latest preference on each call', () => {
    installStorage();
    saveGaoNotePageSize(10);
    expect(readGaoNotePageSize()).toBe(10);
    saveGaoNotePageSize(100);
    expect(readGaoNotePageSize()).toBe(100);
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
