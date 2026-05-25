// FFI for Shell.Clipboard.purs.  Single-shim contract per
// #284 — no logic, just a try/catch around the browser API
// so private-browsing / focus-gated contexts degrade to a
// no-op rather than throwing through the PureScript runtime.

export const writeText = (text) => () => {
  try {
    navigator.clipboard?.writeText(text).catch(() => {});
  } catch {
    /* non-fatal */
  }
};
