"use strict";
// Pinned Lucide SVGs with original ISC/MIT notices; no network, model-generated
// SVG, arbitrary filenames, links, or user-provided executable markup.
const fs=require('node:fs'),path=require('node:path');
const names={metrics:'chart-no-axes-combined',route:'route',timeline:'calendar-days',checklist:'list-checks',services:'briefcase-business',body:'layers'};
const sources=Object.fromEntries(Object.entries(names).map(([kind,name])=>[kind,fs.readFileSync(path.join(__dirname,'design/icons',name+'.svg'),'utf8')]));
function iconSource(kind,color){const svg=Object.hasOwn(sources,kind)?sources[kind]:sources.body;const safe=/^#[0-9A-Fa-f]{6}$/.test(color||'')?color:'#173D34';return 'data:image/svg+xml;base64,'+Buffer.from(svg.replace(/currentColor/g,safe)).toString('base64');}
module.exports={iconSource};
