// Separate the already traced artwork, without fitting or moving any curves.
// Run after trace-app-icon.cjs; dependencies are in docs/design/app-icon.md.
const fs = require('node:fs');
const path = require('node:path');
const { DOMParser, XMLSerializer } = require('@xmldom/xmldom');
const parsePath = require('svg-path-parser');
const { PNG } = require('pngjs');
const { Resvg } = require('@resvg/resvg-js');

const assets = path.resolve(__dirname, '../YamiboX/AppIcon.icon/Assets');
const source = fs.readFileSync(path.join(assets, 'lily.svg'), 'utf8');
const document = new DOMParser().parseFromString(source, 'image/svg+xml');
const paths = document.getElementsByTagName('path');
if (paths.length !== 1 || document.documentElement.getAttribute('viewBox') !== '0 0 1024 1024') {
  throw new Error('Expected the original full-canvas, single compound path');
}
const sourcePath = paths[0];
const subpaths = [];
for (const command of parsePath(sourcePath.getAttribute('d'))) {
  if (command.code === 'M') subpaths.push([]);
  subpaths.at(-1).push(command);
}

// These are the original compound path's connected contours in tracing order.
// Slits (1, 5, 7) stay with their enclosing petal to preserve even-odd holes.
// All tiny flower-center contours are retained.
const layers = [
  { name: 'petal-top', contours: [0, 1] },
  { name: 'petal-upper-left', contours: [2, 3] },
  { name: 'petal-upper-right', contours: [4, 5, 7] },
  { name: 'petal-lower-right', contours: [11, 20] },
  { name: 'petal-lower-left', contours: [12, 21] },
  { name: 'petal-bottom', contours: [22, 23] },
  { name: 'stamens', contours: [6, 8, 9, 10, 13, 14, 15, 16, 17, 18, 19] },
];
const assigned = layers.flatMap(layer => layer.contours).sort((a, b) => a - b);
if (subpaths.length !== 24 || assigned.some((value, index) => value !== index)) {
  throw new Error('Artwork topology changed; review the contour-to-layer mapping');
}

function serializeCommands(commands) {
  return commands.map(command => {
    switch (command.code) {
      case 'M': case 'L': return `${command.code} ${command.x} ${command.y}`;
      case 'C': return `C ${command.x1} ${command.y1} ${command.x2} ${command.y2} ${command.x} ${command.y}`;
      case 'Z': return 'Z';
      default: throw new Error(`Unsupported source command ${command.code}`);
    }
  }).join(' ');
}

const serializer = new XMLSerializer();
const generated = layers.map(layer => {
  const doc = document.cloneNode(true);
  doc.getElementsByTagName('path')[0].setAttribute('d',
    layer.contours.map(index => serializeCommands(subpaths[index])).join(' '));
  return { ...layer, svg: serializer.serializeToString(doc) };
});

// Recombine without materials: splitting must introduce no silhouette changes,
// at both the original resolution and a larger scale that exposes curve edits.
const recombined = document.cloneNode(true);
const root = recombined.documentElement;
root.removeChild(recombined.getElementsByTagName('path')[0]);
for (const layer of generated) {
  const doc = new DOMParser().parseFromString(layer.svg, 'image/svg+xml');
  root.appendChild(recombined.importNode(doc.getElementsByTagName('path')[0], true));
}
for (const width of [1024, 2048]) {
  const options = { fitTo: { mode: 'width', value: width } };
  const before = PNG.sync.read(new Resvg(source, options).render().asPng());
  const after = PNG.sync.read(new Resvg(serializer.serializeToString(recombined), options).render().asPng());
  let changedPixels = 0;
  let maxChannelDifference = 0;
  for (let offset = 0; offset < before.data.length; offset += 4) {
    let changed = false;
    for (let channel = 0; channel < 4; channel++) {
      const difference = Math.abs(before.data[offset + channel] - after.data[offset + channel]);
      maxChannelDifference = Math.max(maxChannelDifference, difference);
      if (difference !== 0) changed = true;
    }
    if (changed) changedPixels++;
  }
  console.log(JSON.stringify({ width, layers: generated.length, changedPixels, maxChannelDifference }));
  if (changedPixels !== 0) throw new Error('Splitting changed the original vector artwork');
}

for (const layer of generated) {
  fs.writeFileSync(path.join(assets, `${layer.name}.svg`), layer.svg.trimEnd() + '\n');
}

// The in-app scene uses the same curves, not the flattened icon preview.
// Groups are front-to-back in Icon Composer; extrusion is built back-to-front.
const icon = JSON.parse(fs.readFileSync(path.join(assets, '../icon.json'), 'utf8'));
const geometry = {
  canvasSize: 1024,
  layers: icon.groups.toReversed().flatMap((group, index) => group.layers.map(layer => {
    const sourceLayer = layers.find(value => `${value.name}.svg` === layer['image-name']);
    if (!sourceLayer) throw new Error(`Unknown interactive layer ${layer['image-name']}`);
    const commands = sourceLayer.contours.flatMap(contour => subpaths[contour]).map(command => {
      switch (command.code) {
        case 'M': return { kind: 'move', values: [command.x, command.y] };
        case 'L': return { kind: 'line', values: [command.x, command.y] };
        case 'C': return { kind: 'curve', values: [command.x1, command.y1, command.x2, command.y2, command.x, command.y] };
        case 'Z': return { kind: 'close', values: [] };
        default: throw new Error(`Unsupported source command ${command.code}`);
      }
    });
    return { name: sourceLayer.name, extrusionDepth: Number((0.045 * (index + 1)).toFixed(3)), commands };
  })),
};
if (geometry.layers.length !== layers.length || new Set(geometry.layers.map(layer => layer.name)).size !== layers.length) {
  throw new Error('Interactive geometry must include each original flower layer exactly once');
}
const resources = path.resolve(assets, '../../../Sources/YamiboXUI/Resources');
fs.mkdirSync(resources, { recursive: true });
fs.writeFileSync(path.join(resources, 'AboutIconGeometry.json'), JSON.stringify(geometry) + '\n');
