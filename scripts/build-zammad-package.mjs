// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { createHash } from "node:crypto";
import { chmod, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = path.resolve("zammad-package");
const metadata = JSON.parse(await readFile(path.join(root, "package-source.json"), "utf8"));
const excluded = new Set(["package-source.json", "wasalx.szpm", "LICENSE", "compatibility-artifacts.json"]);
const textExtensions = new Set([".json", ".po", ".rb", ".ts", ".vue"]);

async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(absolute));
    else files.push(absolute);
  }
  return files;
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

const sources = (await walk(root))
  .filter((file) => !excluded.has(path.relative(root, file)))
  .sort();
const entries = await Promise.all(sources.map(async (file) => {
  const raw = await readFile(file);
  const packaged = textExtensions.has(path.extname(file))
    ? Buffer.from(raw.toString("utf8").replace(/\r\n?/gu, "\n"))
    : raw;
  return {
    location: path.relative(root, file).split(path.sep).join("/"),
    permission: "644",
    content: packaged.toString("base64"),
    source: {
      path: path.relative(process.cwd(), file).split(path.sep).join("/"),
      permission: "644",
      bytes: raw.byteLength,
      sha256: sha256(raw),
    },
    packaged: {
      path: path.relative(root, file).split(path.sep).join("/"),
      permission: "644",
      bytes: packaged.byteLength,
      sha256: sha256(packaged),
    },
  };
}));

const archive = {
  ...metadata,
  files: entries.map(({ location, permission, content }) => ({ location, permission, content })),
};
const outputDirectory = path.resolve("build/zammad");
await mkdir(outputDirectory, { recursive: true });
const outputPath = path.join(outputDirectory, `${metadata.name}-${metadata.version}.zpm`);
const archiveBytes = Buffer.from(`${JSON.stringify(archive, null, 2)}\n`);
await writeFile(outputPath, archiveBytes, { mode: 0o644 });
await chmod(outputPath, 0o644);

const manifestPath = path.join(outputDirectory, `${metadata.name}-${metadata.version}.manifest.json`);
await writeFile(manifestPath, `${JSON.stringify({
  schemaVersion: 1,
  name: metadata.name,
  version: metadata.version,
  package: {
    path: path.relative(process.cwd(), outputPath).split(path.sep).join("/"),
    permission: "644",
    bytes: archiveBytes.byteLength,
    sha256: sha256(archiveBytes),
  },
  files: entries.map(({ location, permission, source, packaged }) => ({ location, permission, source, packaged })),
}, null, 2)}\n`, { mode: 0o644 });
await chmod(manifestPath, 0o644);
process.stdout.write(`${outputPath}\n`);
