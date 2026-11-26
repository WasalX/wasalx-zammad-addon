// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const allowed = JSON.parse(readFileSync(new URL("./copyright-headers.json", import.meta.url), "utf8"));
const notices = new Set(["LICENSE", "THIRD-PARTY-NOTICES"]);
const headerLine = /^[^\p{L}\p{N}]*(Copyright\b.*)$/iu;

function copyrightFindings(path, source) {
  const findings = [];
  for (const [index, line] of source.split(/\r?\n/u).entries()) {
    const match = headerLine.exec(line);
    if (!match) continue;
    const header = match[1].replace(/\s*(?:\*\/|--!?>)\s*$/u, "").trim();
    if (!allowed.some(rule => header === rule.header && path.startsWith(rule.pathPrefix))) {
      findings.push(path + ":" + (index + 1));
    }
  }
  return findings;
}

const paths = execFileSync("git", ["ls-files", "-z"], { encoding: "utf8", windowsHide: true }).split("\0");
for (const path of paths) {
  if (!path || notices.has(path)) continue;
  const bytes = readFileSync(path);
  // Files containing NUL bytes are treated as binaries and have no source headers.
  if (bytes.includes(0)) continue;
  for (const finding of copyrightFindings(path, bytes.toString("utf8"))) {
    console.error(finding + ": unapproved copyright header");
    process.exitCode = 1;
  }
}
