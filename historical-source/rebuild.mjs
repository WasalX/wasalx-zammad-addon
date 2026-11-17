// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
import {readFile,mkdir,writeFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import assert from "node:assert/strict";
import {resolve,dirname} from "node:path";
import {fileURLToPath} from "node:url";
const root=resolve(dirname(fileURLToPath(import.meta.url)),"..");
const output=process.argv[2];
assert(output,"Supply a separate output directory");
for(const entry of JSON.parse(await readFile(new URL("./index.json",import.meta.url),"utf8"))){
 for(let i=0;i<entry.package.files.length;i++)entry.package.files[i].content=(await readFile(resolve(root,entry.sources[i]))).toString("base64");
 const bytes=Buffer.from(JSON.stringify(entry.package,null,entry.indent)+(entry.newline?"\n":""));
 assert.equal(createHash("sha256").update(bytes).digest("hex"),entry.sha256,"Historical source reconstruction mismatch");
 const path=resolve(output,entry.path);await mkdir(dirname(path),{recursive:true});await writeFile(path,bytes,{flag:"wx"});
}
