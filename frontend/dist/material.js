// Material Web Components loader.
//
// Pulls @material/web (v2) from esm.run (a CDN-mirrored ESM
// of the npm package) and registers every <md-*> custom
// element. Also adopts the Material 3 typescale stylesheet
// so the .md-typescale-* classes work on plain HTML.
//
// This file is the SINGLE script that boots the Material
// runtime; everything else (Halogen app, theme state) is
// PureScript. Loaded by index.html via:
//   <script type="module" src="./material.js"></script>
//
// CDN choice (esm.run) keeps this static + cacheable. A
// future change will pin a specific version and optionally
// vendor the bundle via nix/fetchurl so the image is fully
// content-addressed.

import "https://esm.run/@material/web@2.0.0/all.js";
import { styles as typescaleStyles }
  from "https://esm.run/@material/web@2.0.0/typography/md-typescale-styles.js";

document.adoptedStyleSheets.push(typescaleStyles.styleSheet);
