// Decode the rendered screenshots in software, including on headless simulator hosts.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import jsQR from "jsqr";
import { PNG } from "pngjs";

const dir = process.argv[2];
const manifest = JSON.parse(readFileSync(join(dir, "manifest.json")));
const verified = new Set();
for (const test of manifest) {
  for (const file of test.attachments) {
    const match = /(local|public)-qr-([a-f0-9]{64})/.exec(file.suggestedHumanReadableName);
    if (!match) continue;
    const png = PNG.sync.read(readFileSync(join(dir, file.exportedFileName)));
    const qr = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
    assert.ok(qr, "Could not decode the " + match[1] + " QR code");
    assert.equal(createHash("sha256").update(qr.data).digest("hex"), match[2], "QR and displayed link must match");
    verified.add(match[1]);
  }
}
assert.deepEqual(verified, new Set(["local", "public"]));
console.log("Both rendered QR codes decode to their displayed gallery URLs.");
