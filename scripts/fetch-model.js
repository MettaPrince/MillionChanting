#!/usr/bin/env node
// Downloads the large int8 encoder weight at build time.
//
// The Thai Zipformer's int8 encoder (~147MB) can't live in git: it's over
// GitHub's 100MB per-file limit. Instead it's stored as a release asset on
// this (private) repo and pulled down here during `npm install` (wired as the
// "postinstall" script in package.json), so Render fetches it on every build.
//
// Everything else the model needs (decoder/joiner int8, tokens.txt,
// bpe_vocab.txt, bpe.model) is small and committed directly in model/.
//
// Because the repo is PRIVATE, the release asset is not anonymously
// downloadable — set a GITHUB_TOKEN env var (a token with read access to this
// repo's contents) in the Render dashboard. Locally / in Codespace the file is
// usually already present, so this script no-ops without needing a token.

const fs = require('fs');
const path = require('path');
const https = require('https');

const REPO = 'MettaPrince/MillionChanting';
const RELEASE_TAG = 'models-v1';
const ASSET_NAME = 'encoder-epoch-12-avg-5.int8.onnx';
const DEST = path.join(__dirname, '..', 'model', ASSET_NAME);
// The int8 encoder is ~147MB; treat anything much smaller as a truncated /
// failed download rather than a valid file.
const MIN_VALID_BYTES = 100 * 1024 * 1024;

const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;

function log(msg) { console.log(`[fetch-model] ${msg}`); }

function get(url, headers) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'fetch-model', ...headers } }, resolve).on('error', reject);
  });
}

// Follow GitHub's redirect chain to the signed asset URL, streaming the body
// only once we reach a 200 so we never buffer 147MB in memory.
async function downloadTo(url, headers, dest) {
  const res = await get(url, headers);
  if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
    res.resume(); // drain
    // The signed S3/blob URL rejects the Authorization header — drop it.
    return downloadTo(res.headers.location, { Accept: headers.Accept }, dest);
  }
  if (res.statusCode !== 200) {
    res.resume();
    throw new Error(`HTTP ${res.statusCode} fetching asset (check GITHUB_TOKEN has repo read access)`);
  }
  await new Promise((resolve, reject) => {
    const tmp = `${dest}.partial`;
    const file = fs.createWriteStream(tmp);
    res.pipe(file);
    file.on('finish', () => file.close(() => { fs.renameSync(tmp, dest); resolve(); }));
    file.on('error', (err) => { fs.unlink(tmp, () => reject(err)); });
    res.on('error', reject);
  });
}

async function main() {
  if (fs.existsSync(DEST) && fs.statSync(DEST).size >= MIN_VALID_BYTES) {
    log(`encoder already present (${(fs.statSync(DEST).size / 1e6).toFixed(0)}MB), skipping download.`);
    return;
  }

  if (!token) {
    log('encoder missing and no GITHUB_TOKEN set.');
    log('This is fine for local/Codespace if the file is already in model/.');
    log('On Render: add a GITHUB_TOKEN env var with read access to ' + REPO + '.');
    // Don't hard-fail the whole `npm install` — let the server's own startup
    // check produce the clear "model not found" error if it truly is missing.
    return;
  }

  log(`downloading ${ASSET_NAME} from ${REPO}@${RELEASE_TAG} ...`);
  const relUrl = `https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}`;
  const relRes = await get(relUrl, { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json' });
  let body = '';
  for await (const chunk of relRes) body += chunk;
  if (relRes.statusCode !== 200) throw new Error(`HTTP ${relRes.statusCode} fetching release metadata: ${body.slice(0, 200)}`);
  const release = JSON.parse(body);
  const asset = (release.assets || []).find((a) => a.name === ASSET_NAME);
  if (!asset) throw new Error(`asset ${ASSET_NAME} not found in release ${RELEASE_TAG}`);

  fs.mkdirSync(path.dirname(DEST), { recursive: true });
  await downloadTo(asset.url, { Authorization: `Bearer ${token}`, Accept: 'application/octet-stream' }, DEST);
  log(`done: ${(fs.statSync(DEST).size / 1e6).toFixed(0)}MB -> ${DEST}`);
}

main().catch((err) => {
  console.error(`[fetch-model] ${err.message}`);
  process.exit(1);
});
