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

// #289 slice F — variant that calls back with a Boolean so
// the caller can surface success / failure feedback.  The
// PureScript side wraps this with `makeAff` to lift it
// into `Aff Boolean` (avoids the aff-promise dep).
export const _writeTextResult = (text) => (cb) => () => {
  const succeed = () => cb(true)();
  const fail = () => cb(false)();
  try {
    if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") {
      fail();
      return;
    }
    navigator.clipboard.writeText(text).then(succeed, fail);
  } catch {
    fail();
  }
};
