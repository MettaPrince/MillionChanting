#!/usr/bin/env node
// Downloads the large int8 encoder weight at build time.
//
// The Thai Zipformer's int8 encoder (~147MB) can't live in git: it's over
// GitHub's 100MB per-file limit. Instead it's stored as a release asset on
// this (public) repo and pulled down here during `npm install` (wired as the
// "postinstall" script in package.json), so Render fetches it on every build.
// Public release assets download anonymously, no token needed.
//
// Everything else the model needs (decoder/joiner int8, tokens.txt,
// bpe_vocab.txt, bpe.model) is small and committed directly in model/.

const fs = require('fs');
const path = require('path');
const https = require('https');

const ASSET_URL = 'https://github.com/MettaPrince/MillionChanting/releases/download/models-v1/encoder-epoch-12-avg-5.int8.onnx';
const ASSET_NAME = 'encoder-epoch-12-avg-5.int8.onnx';
const DEST = path.join(__dirname, '..', 'model', ASSET_NAME);
// The int8 encoder is ~147MB; treat anything much smaller as a truncated /
// failed download rather than a valid file.
const MIN_VALID_BYTES = 100 * 1024 * 1024;

function log(msg) { console.log(`[fetch-model] ${msg}`); }

function downloadTo(url, dest) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'fetch-model' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume(); // drain, follow redirect
        downloadTo(res.headers.location, dest).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) {
        res.resume();
        reject(new Error(`HTTP ${res.statusCode} fetching ${url}`));
        return;
      }
      const tmp = `${dest}.partial`;
      const file = fs.createWriteStream(tmp);
      res.pipe(file);
      file.on('finish', () => file.close(() => { fs.renameSync(tmp, dest); resolve(); }));
      file.on('error', (err) => { fs.unlink(tmp, () => reject(err)); });
      res.on('error', reject);
    }).on('error', reject);
  });
}

async function main() {
  if (fs.existsSync(DEST) && fs.statSync(DEST).size >= MIN_VALID_BYTES) {
    log(`encoder already present (${(fs.statSync(DEST).size / 1e6).toFixed(0)}MB), skipping download.`);
    return;
  }

  log(`downloading ${ASSET_NAME} ...`);
  fs.mkdirSync(path.dirname(DEST), { recursive: true });
  await downloadTo(ASSET_URL, DEST);
  log(`done: ${(fs.statSync(DEST).size / 1e6).toFixed(0)}MB -> ${DEST}`);
}

main().catch((err) => {
  console.error(`[fetch-model] ${err.message}`);
  process.exit(1);
});
