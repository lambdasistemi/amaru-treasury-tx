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
