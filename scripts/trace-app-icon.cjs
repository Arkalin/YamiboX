// Reproduce the original artwork's silhouette without redrawing or repositioning it.
// Temporary tooling dependencies and invocation are documented in docs/design/app-icon.md.
const fs = require('node:fs');
const path = require('node:path');
const { PNG } = require('pngjs');
const { trace } = require('potrace');
const { Resvg } = require('@resvg/resvg-js');

const root = path.resolve(__dirname, '..');
const source = PNG.sync.read(fs.readFileSync(path.join(root,
  'YamiboX/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')));
const { width, height } = source;
if (width !== 1024 || height !== 1024) throw new Error('Expected the original 1024px icon');

// Representative original colors. Project onto their connecting line to recover
// the half-coverage contour without interpreting raster color noise as new shapes.
const background = [82, 28, 10];
const foreground = [244, 237, 228];
const delta = foreground.map((value, channel) => value - background[channel]);
const denominator = delta.reduce((sum, value) => sum + value * value, 0);
const mask = new Uint8Array(width * height);
const coverage = new Float32Array(width * height);
for (let pixel = 0; pixel < mask.length; pixel++) {
  let projection = 0;
  for (let channel = 0; channel < 3; channel++) {
    projection += (source.data[pixel * 4 + channel] - background[channel]) * delta[channel];
  }
  coverage[pixel] = Math.max(0, Math.min(1, projection / denominator));
  mask[pixel] = coverage[pixel] >= 0.5 ? 1 : 0;
}

// Trace at 4x using the original antialiasing, not a staircase of whole pixels.
const scale = 4;
const bitmap = new PNG({ width: width * scale, height: height * scale });
for (let y = 0; y < bitmap.height; y++) {
  for (let x = 0; x < bitmap.width; x++) {
    const sx = Math.max(0, Math.min(width - 1, (x + 0.5) / scale - 0.5));
    const sy = Math.max(0, Math.min(height - 1, (y + 0.5) / scale - 0.5));
    const x0 = Math.floor(sx), y0 = Math.floor(sy);
    const x1 = Math.min(width - 1, x0 + 1), y1 = Math.min(height - 1, y0 + 1);
    const fx = sx - x0, fy = sy - y0;
    const top = coverage[y0 * width + x0] * (1 - fx) + coverage[y0 * width + x1] * fx;
    const bottom = coverage[y1 * width + x0] * (1 - fx) + coverage[y1 * width + x1] * fx;
    const offset = (y * bitmap.width + x) * 4;
    bitmap.data.fill(top * (1 - fy) + bottom * fy >= 0.5 ? 0 : 255, offset, offset + 3);
    bitmap.data[offset + 3] = 255;
  }
}

trace(PNG.sync.write(bitmap), {
  threshold: 128,
  blackOnWhite: true,
  turdSize: 0,
  alphaMax: 1,
  optCurve: true,
  optTolerance: 0.05,
  width,
  height,
  color: '#F4EDE4',
  background: 'transparent',
}, (error, svg) => {
  if (error) throw error;
  const rendered = PNG.sync.read(new Resvg(svg).render().asPng());
  let sourceArea = 0;
  let intersection = 0;
  let union = 0;
  let differingPixels = 0;
  let interiorDifferences = 0;
  for (let pixel = 0; pixel < mask.length; pixel++) {
    const actual = rendered.data[pixel * 4 + 3] >= 128 ? 1 : 0;
    sourceArea += mask[pixel];
    intersection += actual & mask[pixel];
    union += actual | mask[pixel];
    if (actual === mask[pixel]) continue;
    differingPixels++;
    const x = pixel % width;
    const y = Math.floor(pixel / width);
    let onEdge = false;
    for (let dy = -1; dy <= 1; dy++) {
      for (let dx = -1; dx <= 1; dx++) {
        if (x + dx < 0 || x + dx >= width || y + dy < 0 || y + dy >= height) continue;
        if (mask[(y + dy) * width + x + dx] !== mask[pixel]) onEdge = true;
      }
    }
    if (!onEdge) interiorDifferences++;
  }
  const iou = intersection / union;
  console.log(JSON.stringify({ width, height, sourceArea, differingPixels,
    silhouetteIoU: iou, differencesBeyondOnePixelEdge: interiorDifferences }, null, 2));
  if (iou < 0.995 || interiorDifferences !== 0) {
    throw new Error('Trace deviates from the original silhouette');
  }
  fs.writeFileSync(path.join(root, 'YamiboX/AppIcon.icon/Assets/lily.svg'), svg + '\n');
});
