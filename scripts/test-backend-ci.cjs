'use strict';
const {readdirSync}=require('node:fs');
const {join,resolve}=require('node:path');
const {spawnSync}=require('node:child_process');

const root=resolve(__dirname,'..');
const directory=join(root,'tests-backend');
// These forensic scripts target frozen worktrees from the November 21–22 investigation.
// The current source is covered by the release suite, including image reference and tool contracts.
const archivedReplays=new Set(['prompt-contract-20261121.test.js','reference-conflict-20261122.test.js']);
const files=readdirSync(directory).filter(name=>name.endsWith('.test.js')&&!archivedReplays.has(name)).sort();
console.log('Archival worktree replays run separately: '+ [...archivedReplays].join(', '));
const result=spawnSync(process.execPath,['--test',...files.map(name=>join(directory,name))],{cwd:root,stdio:'inherit'});
process.exit(result.status??1);

