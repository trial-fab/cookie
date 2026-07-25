const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const FRAME_SIZE = 128;
const PADDING = 2;
const CELL_SIZE = FRAME_SIZE + PADDING * 2;
const COLUMNS = 11;
const FRAME_COUNT = 101;
const ROWS = Math.ceil(FRAME_COUNT / COLUMNS);
const SUPERSAMPLE = 3;

const CENTER = FRAME_SIZE / 2;
const RADIUS = 46;
const THICKNESS = 10;
const GAP_DEGREES = 70;
const START_DEGREES = GAP_DEGREES / 2;
const ARC_DEGREES = 360 - GAP_DEGREES;
const COLOR = [39, 226, 255, 255];

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBuffer = Buffer.from(type, "ascii");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])));
  return Buffer.concat([length, typeBuffer, data, checksum]);
}

function writePng(filename, width, height, rgba) {
  const scanlines = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y += 1) {
    const destination = y * (width * 4 + 1);
    scanlines[destination] = 0;
    rgba.copy(scanlines, destination + 1, y * width * 4, (y + 1) * width * 4);
  }

  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;

  const png = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(scanlines, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  fs.writeFileSync(filename, png);
}

function angularDistanceFromStart(degrees) {
  return (degrees - START_DEGREES + 360) % 360;
}

function sampleArc(localX, localY, progress) {
  const dx = localX - CENTER;
  const dy = localY - CENTER;
  const distance = Math.sqrt(dx * dx + dy * dy);
  if (Math.abs(distance - RADIUS) > THICKNESS / 2) {
    return false;
  }

  let degrees = (Math.atan2(dy, dx) * 180) / Math.PI;
  if (degrees < 0) degrees += 360;
  const alongArc = angularDistanceFromStart(degrees);
  return alongArc <= ARC_DEGREES * progress;
}

function renderFrame(progress) {
  const rgba = Buffer.alloc(FRAME_SIZE * FRAME_SIZE * 4);
  const samples = SUPERSAMPLE * SUPERSAMPLE;

  for (let y = 0; y < FRAME_SIZE; y += 1) {
    for (let x = 0; x < FRAME_SIZE; x += 1) {
      let covered = 0;
      for (let sy = 0; sy < SUPERSAMPLE; sy += 1) {
        for (let sx = 0; sx < SUPERSAMPLE; sx += 1) {
          const px = x + (sx + 0.5) / SUPERSAMPLE;
          const py = y + (sy + 0.5) / SUPERSAMPLE;
          if (sampleArc(px, py, progress)) covered += 1;
        }
      }

      const index = (y * FRAME_SIZE + x) * 4;
      rgba[index] = COLOR[0];
      rgba[index + 1] = COLOR[1];
      rgba[index + 2] = COLOR[2];
      rgba[index + 3] = Math.round((covered / samples) * COLOR[3]);
    }
  }
  return rgba;
}

function blit(source, sourceWidth, sourceHeight, target, targetWidth, xOffset, yOffset) {
  for (let y = 0; y < sourceHeight; y += 1) {
    const sourceStart = y * sourceWidth * 4;
    const targetStart = ((y + yOffset) * targetWidth + xOffset) * 4;
    source.copy(target, targetStart, sourceStart, sourceStart + sourceWidth * 4);
  }
}

function checkerboard(width, height) {
  const rgba = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const shade = (Math.floor(x / 8) + Math.floor(y / 8)) % 2 ? 42 : 64;
      const index = (y * width + x) * 4;
      rgba[index] = shade;
      rgba[index + 1] = shade;
      rgba[index + 2] = shade;
      rgba[index + 3] = 255;
    }
  }
  return rgba;
}

function alphaComposite(source, target, targetWidth, xOffset, yOffset) {
  for (let y = 0; y < FRAME_SIZE; y += 1) {
    for (let x = 0; x < FRAME_SIZE; x += 1) {
      const sourceIndex = (y * FRAME_SIZE + x) * 4;
      const targetIndex = ((y + yOffset) * targetWidth + x + xOffset) * 4;
      const alpha = source[sourceIndex + 3] / 255;
      for (let channel = 0; channel < 3; channel += 1) {
        target[targetIndex + channel] = Math.round(
          source[sourceIndex + channel] * alpha +
            target[targetIndex + channel] * (1 - alpha),
        );
      }
    }
  }
}

const outputDirectory = path.join(__dirname, "..", "docs", "quest-ring-draft");
fs.mkdirSync(outputDirectory, { recursive: true });

const atlasWidth = COLUMNS * CELL_SIZE;
const atlasHeight = ROWS * CELL_SIZE;
const atlas = Buffer.alloc(atlasWidth * atlasHeight * 4);
const frames = [];

for (let index = 0; index < FRAME_COUNT; index += 1) {
  const frame = renderFrame(index / 100);
  frames.push(frame);
  const column = index % COLUMNS;
  const row = Math.floor(index / COLUMNS);
  blit(
    frame,
    FRAME_SIZE,
    FRAME_SIZE,
    atlas,
    atlasWidth,
    column * CELL_SIZE + PADDING,
    row * CELL_SIZE + PADDING,
  );
}

writePng(
  path.join(outputDirectory, "quest-ring-spritesheet-draft.png"),
  atlasWidth,
  atlasHeight,
  atlas,
);

const previewIndexes = [0, 25, 50, 75, 100];
const previewGap = 12;
const previewWidth =
  previewIndexes.length * FRAME_SIZE + (previewIndexes.length + 1) * previewGap;
const previewHeight = FRAME_SIZE + previewGap * 2;
const preview = checkerboard(previewWidth, previewHeight);

previewIndexes.forEach((frameIndex, index) => {
  alphaComposite(
    frames[frameIndex],
    preview,
    previewWidth,
    previewGap + index * (FRAME_SIZE + previewGap),
    previewGap,
  );
});

writePng(
  path.join(outputDirectory, "quest-ring-preview-draft.png"),
  previewWidth,
  previewHeight,
  preview,
);

const metadata = {
  frameCount: FRAME_COUNT,
  frameSize: { x: FRAME_SIZE, y: FRAME_SIZE },
  padding: PADDING,
  cellSize: { x: CELL_SIZE, y: CELL_SIZE },
  columns: COLUMNS,
  rows: ROWS,
  atlasSize: { x: atlasWidth, y: atlasHeight },
  frameOrder: "left-to-right, then top-to-bottom, 0 through 100 percent",
};
fs.writeFileSync(
  path.join(outputDirectory, "quest-ring-spritesheet-draft.json"),
  `${JSON.stringify(metadata, null, 2)}\n`,
);

console.log(`Wrote draft assets to ${outputDirectory}`);
