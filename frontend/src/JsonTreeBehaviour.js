// JsonView collapse semantics:
//   - single click on a v-key-toggle / v-sep-toggle
//     summary: opens just that one level.  When
//     closing, cascades down so descendants close too
//     (so a later reopen starts at one-level depth
//     again).  Symmetry: closing recursively is just
//     a single click on an open node.
//   - double click: always expands the whole subtree
//     recursively, never collapses.  (A double-click
//     that closed an open node was counter-intuitive
//     — the gesture should commit to "show me
//     everything".)

const isJsonTreeSummary = (s) =>
  !!s &&
  (s.classList.contains("v-key-toggle") ||
    s.classList.contains("v-sep-toggle"));

const detailsOf = (summary) => {
  const d = summary.parentElement;
  return d && d.tagName === "DETAILS" ? d : null;
};

const cascade = (details, open) => {
  details
    .querySelectorAll("details")
    .forEach((d) => {
      d.open = open;
    });
};

const handleClick = (e) => {
  const summary = e.target.closest("summary");
  if (!isJsonTreeSummary(summary)) return;
  const details = detailsOf(summary);
  if (!details) return;
  e.preventDefault();
  const willOpen = !details.open;
  details.open = willOpen;
  if (!willOpen) cascade(details, false);
};

const handleDblClick = (e) => {
  const summary = e.target.closest("summary");
  if (!isJsonTreeSummary(summary)) return;
  const details = detailsOf(summary);
  if (!details) return;
  e.preventDefault();
  details.open = true;
  cascade(details, true);
  if (window.getSelection) {
    window.getSelection().removeAllRanges();
  }
};

// Copy-to-clipboard handler.  Fires before the
// summary handler so the click on the v-copy button
// nested inside a linked txid / addr / policy
// doesn't also toggle the surrounding <details>.
const handleCopyClick = (e) => {
  const btn = e.target.closest(".v-copy");
  if (!btn) return;
  e.preventDefault();
  e.stopPropagation();
  const val = btn.getAttribute("data-copy") || "";
  if (navigator.clipboard && val) {
    navigator.clipboard.writeText(val).catch(() => {});
  }
  btn.classList.add("v-copy--ok");
  setTimeout(() => btn.classList.remove("v-copy--ok"), 700);
};

export const install = () => {
  // Capture phase so the copy click runs before the
  // summary click bubbles up and toggles the parent
  // <details>.
  document.addEventListener("click", handleCopyClick, true);
  document.addEventListener("click", handleClick);
  document.addEventListener("dblclick", handleDblClick);
};
