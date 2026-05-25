// FFI for OperatePage.purs.
//
// `_focusById` is the slice-D progress-chip jump handler:
// scroll the named element into view and move keyboard
// focus to it.  Both calls degrade to no-ops when the id
// isn't on the page (e.g. the section's first field isn't
// rendered in the active mode).

export const _focusById = (id) => () => {
  const el = document.getElementById(id);
  if (!el) return;
  try {
    el.scrollIntoView({ behavior: "smooth", block: "center" });
  } catch {
    /* older browsers without smooth-scroll options */
    el.scrollIntoView();
  }
  if (typeof el.focus === "function") {
    el.focus({ preventScroll: true });
  }
};
