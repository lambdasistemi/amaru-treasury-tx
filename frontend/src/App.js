// FFI for App.purs.
//
// Single helper: `nowIso :: Effect String` returns the current
// wall-clock time formatted as a compact ISO-8601 stamp
// (HH:MM:SS UTC) for the "last refresh" status chip. Trimmed
// to seconds because the chip is operator-facing — millisecond
// precision would be noise.

export const nowIso = () =>
  new Date().toISOString().replace(/\.\d+Z$/, "Z").replace("T", " ");
