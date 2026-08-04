# WorldMap third-party notices

This directory vendors fixed upstream runtime distributions and generated local wrappers for offline application bundling. The app does not load executable code or map data from a CDN.

## MapLibre GL JS 5.12.0

- Project: https://github.com/maplibre/maplibre-gl-js
- License: BSD 3-Clause
- Vendored files: `maplibre-gl.js` (CSP build), `maplibre-gl-worker.js`, generated
  `maplibre-gl-worker-source.js`, `maplibre-gl.css`

Copyright (c) 2023, MapLibre contributors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the copyright notice, conditions and disclaimer in the package `LICENSE.txt` are retained. The complete upstream license is stored as `LICENSE-maplibre.txt` beside this notice.

## deck.gl 9.3.7

- Project: https://github.com/visgl/deck.gl
- License: MIT
- Vendored file: `deck.gl.min.js`

Copyright Vis.gl contributors.

Permission is granted, free of charge, to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, subject to inclusion of the copyright and permission notice. The complete upstream license is stored as `LICENSE-deck.gl.txt` beside this notice.

## Natural Earth 1:110m Admin 0 countries

- Project: https://www.naturalearthdata.com/
- Source: https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_admin_0_countries.geojson
- Terms: public domain
- Vendored generated file: `natural-earth-countries.js`
- Retrieved: 2026-08-04
- Upstream GeoJSON SHA-256: `6866c877d39cba9c357620878839b336d569f8c662d3cfab4cb1dbe2d39c977f`

Natural Earth states that all of its raster and vector map data is in the public domain. The vendored JavaScript file wraps the upstream GeoJSON object in a local global assignment so `WKWebView.loadFileURL` can load it without network access or filesystem XHR. No geometry or properties are changed.
