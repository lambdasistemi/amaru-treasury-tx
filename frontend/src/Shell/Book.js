// FFI for Shell.Book.purs.  Wraps window.localStorage with
// try/catch so private-browsing, denied-storage, or
// quota-exceeded environments degrade to no-ops rather
// than throwing through the PureScript runtime.

export const _get = (k) => () => {
  try {
    return localStorage.getItem(k) ?? "";
  } catch {
    return "";
  }
};

export const _set = (k) => (v) => () => {
  try {
    localStorage.setItem(k, v);
  } catch {
    /* private browsing, quota exceeded — non-fatal */
  }
};

export const _remove = (k) => () => {
  try {
    localStorage.removeItem(k);
  } catch {
    /* non-fatal */
  }
};
