// #239 T012 — esbuild entry point for the dashboard bundle.
//
// v1 has no npm dependencies; this file exists solely so the
// build phase produces a `dist/deps.js` artefact that gets
// concatenated ahead of the PureScript output. Add npm-side
// globals here (and to `package.json`) when later slices need
// them — see /code/graph-browser-view-export-import/src/bootstrap.js
// for the pattern.

// Intentionally empty IIFE body.
