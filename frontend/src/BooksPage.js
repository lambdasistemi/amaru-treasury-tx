// FFI shims for BooksPage.purs slice D — file download,
// clipboard, file picker reading, and UTC-stamp
// generation.  All operations degrade to no-ops on
// browsers that deny clipboard / blob URLs (private
// browsing, sandboxed iframes).

// Download a JSON string as <filename>.  Creates a
// transient blob URL, programmatic-clicks an <a>, and
// revokes the URL on the next tick.
export const _downloadText = (filename) => (content) => () => {
  try {
    const blob = new Blob([content], {
      type: "application/json",
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 0);
  } catch {
    /* non-fatal — browser denied blob URLs */
  }
};

// Asynchronously read the first selected file from a
// <input type="file"> identified by CSS selector and pass
// its contents to onSuccess.  Empty selection resolves
// with "".  IO errors call onError.
export const _readFileFromInput =
  (selector) => (onSuccess) => (onError) => () => {
    try {
      const input = document.querySelector(selector);
      const file = input?.files?.[0];
      if (!file) {
        onSuccess("")();
        return;
      }
      const reader = new FileReader();
      reader.onload = () => onSuccess(String(reader.result))();
      reader.onerror = () =>
        onError(new Error("failed to read file"))();
      reader.readAsText(file);
    } catch (e) {
      onError(e instanceof Error ? e : new Error(String(e)))();
    }
  };
