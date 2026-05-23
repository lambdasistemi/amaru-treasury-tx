// FFI for Theme.purs. localStorage + matchMedia + the
// data-theme attribute on the document root.

const STORE_KEY = "amaru-treasury-theme";

export const _getStored = () => {
  try {
    return localStorage.getItem(STORE_KEY) ?? "";
  } catch {
    return "";
  }
};

export const _setStored = (v) => () => {
  try {
    localStorage.setItem(STORE_KEY, v);
  } catch {
    /* private browsing etc. — non-fatal */
  }
};

export const _prefersLight = () =>
  window.matchMedia("(prefers-color-scheme: light)").matches;

export const _setHtmlTheme = (v) => () => {
  document.documentElement.setAttribute("data-theme", v);
};
