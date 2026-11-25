// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { chmod, lstat, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const [artifactPath, destination, expectedName, expectedVersion] = process.argv.slice(2);
if (!artifactPath || !destination || !expectedName || !expectedVersion) {
  throw new Error("usage: unpack-zpm <artifact> <destination> <name> <version>");
}
if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/u.test(expectedName)) {
  throw new Error("Zammad package name is invalid");
}

const archive = JSON.parse(await readFile(artifactPath, "utf8"));
if (archive.name !== expectedName || archive.version !== expectedVersion) {
  throw new Error("Zammad package identity does not match the image build contract");
}
if (!Array.isArray(archive.files) || archive.files.length === 0) {
  throw new Error("Zammad package contains no files");
}

const destinationRoot = path.resolve(destination);

function prepareEntry(entry) {
  if (
    typeof entry?.location !== "string"
    || !/^[a-zA-Z0-9._/-]+$/u.test(entry.location)
    || path.posix.isAbsolute(entry.location)
    || path.posix.normalize(entry.location) !== entry.location
    || entry.location.startsWith("../")
    || entry.permission !== "644"
    || typeof entry.content !== "string"
  ) {
    throw new Error("Zammad package contains an unsafe file entry");
  }
  const bytes = Buffer.from(entry.content, "base64");
  if (bytes.length === 0 || bytes.toString("base64") !== entry.content) {
    throw new Error(`Zammad package file ${entry.location} has invalid content`);
  }
  const output = path.resolve(destinationRoot, ...entry.location.split("/"));
  if (!output.startsWith(`${destinationRoot}${path.sep}`)) {
    throw new Error("Zammad package file escapes the application directory");
  }
  return { bytes, location: entry.location, output };
}

async function priorPackageFiles() {
  const installedArtifact = path.join(destinationRoot, "contrib", `${expectedName}.zpm`);
  let value;
  try {
    value = JSON.parse(await readFile(installedArtifact, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return new Map();
    throw new Error("Existing Zammad package ownership record is invalid", { cause: error });
  }
  if (value.name !== expectedName || !Array.isArray(value.files)) {
    throw new Error("Existing Zammad package ownership record is invalid");
  }
  const owned = new Map();
  for (const entry of value.files) {
    const prepared = prepareEntry(entry);
    if (owned.has(prepared.location)) {
      throw new Error("Existing Zammad package ownership record is invalid");
    }
    owned.set(prepared.location, prepared.bytes);
  }
  return owned;
}

const preparedEntries = archive.files.map(prepareEntry);
if (new Set(preparedEntries.map((entry) => entry.location)).size !== preparedEntries.length) {
  throw new Error("Zammad package contains duplicate file entries");
}

const previouslyOwned = await priorPackageFiles();
for (const entry of preparedEntries) {
  let status;
  try {
    status = await lstat(entry.output);
  } catch (error) {
    if (error?.code === "ENOENT") continue;
    throw error;
  }
  const priorBytes = previouslyOwned.get(entry.location);
  if (!status.isFile() || !priorBytes || !(await readFile(entry.output)).equals(priorBytes)) {
    throw new Error(`Zammad package file ${entry.location} collides with an existing non-package file`);
  }
}

for (const { bytes, output } of preparedEntries) {
  await mkdir(path.dirname(output), { recursive: true });
  await writeFile(output, bytes, { mode: 0o644 });
  await chmod(output, 0o644);
}

process.stdout.write(`unpacked ${archive.name}-${archive.version} (${archive.files.length} files)\n`);
