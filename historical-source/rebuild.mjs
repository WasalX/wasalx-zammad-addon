// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 WasalX
import {readFile,mkdir,writeFile} from "node:fs/promises";
import {execFileSync} from "node:child_process";
import {createHash} from "node:crypto";
import assert from "node:assert/strict";
import {resolve,dirname} from "node:path";
import {fileURLToPath} from "node:url";
const root=resolve(dirname(fileURLToPath(import.meta.url)),"..");
const output=process.argv[2];
assert(output,"Supply a separate output directory");
// Retained packages record the source bytes before copyright normalization.
const sourceRevision = "33d9fd2aa2fcfebe2be057c08416f2200d790ee5";
const gitOptions = {cwd:root,windowsHide:true};
try {
 execFileSync("git",["cat-file","-e",sourceRevision + "^{tree}"],gitOptions);
} catch (cause) {
 throw new Error("Historical rebuild requires the source revision " + sourceRevision + " in local Git history",{cause});
}
for(const entry of JSON.parse(await readFile(new URL("./index.json",import.meta.url),"utf8"))){
 for(let i=0;i<entry.package.files.length;i++)entry.package.files[i].content=execFileSync("git",["show",sourceRevision + ":" + entry.sources[i]],gitOptions).toString("base64");
 const bytes=Buffer.from(JSON.stringify(entry.package,null,entry.indent)+(entry.newline?"\n":""));
 assert.equal(createHash("sha256").update(bytes).digest("hex"),entry.sha256,"Historical source reconstruction mismatch");
 const path=resolve(output,entry.path);await mkdir(dirname(path),{recursive:true});await writeFile(path,bytes,{flag:"wx"});
}
