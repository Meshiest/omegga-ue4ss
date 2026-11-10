// Query a UE4SS object dump for UFunction signatures.
//
//   npm run dumpq -- <UE4SS_ObjectDump.txt> <class regex> [function regex]
//
// Make the dump with `emitPlugin('exec', 'DumpAllObjects()')` (or from any mod);
// it lands in data/UE4SS/UE4SS_ObjectDump.txt. Prints each matching /Script
// function as `Class:Function(Param: Type @offset, ...)`, with struct, class and
// enum pointers resolved to names. Offsets are what BR.call / __fn_layout use.
import fs from 'node:fs';
import readline from 'node:readline';

const LINE = /^\[([0-9A-F]+)\] (\w+) (\S+)(.*)$/;
const ATTR = /\[(\w+): ([0-9A-Fa-f]+)\]/g;

async function main() {
  const [dump, classRe, fnRe] = process.argv.slice(2);
  if (!dump || !classRe) {
    console.error('usage: dumpq <UE4SS_ObjectDump.txt> <class regex> [function regex]');
    process.exit(2);
  }
  // a leading (?i) means case-insensitive, as in Python and PCRE
  const regex = (re: string) => (re.startsWith('(?i)') ? new RegExp(re.slice(4), 'i') : new RegExp(re));
  const cls = regex(classRe);
  const fn = fnRe ? regex(fnRe) : null;
  const names = new Map<string, string>();
  const functions: string[] = [];
  const params = new Map<string, { name: string; kind: string; attrs: Map<string, string> }[]>();

  const rl = readline.createInterface({ input: fs.createReadStream(dump), crlfDelay: Infinity });
  for await (const line of rl) {
    const m = LINE.exec(line);
    if (!m) continue;
    const [, addr, kind, full, tail] = m;
    const attrs = new Map([...tail.matchAll(ATTR)].map(a => [a[1], a[2]]));
    names.set(addr, full.slice(full.lastIndexOf('.') + 1));
    if (kind === 'Function') functions.push(full);
    else if (kind.endsWith('Property') && full.split(':').length === 3) {
      const owner = full.slice(0, full.lastIndexOf(':'));
      const list = params.get(owner) ?? [];
      list.push({ name: full.slice(full.lastIndexOf(':') + 1), kind, attrs });
      params.set(owner, list);
    }
  }

  const typeOf = (kind: string, attrs: Map<string, string>) => {
    for (const key of ['ss', 'pc', 'em']) {
      const ptr = attrs.get(key);
      if (ptr) return `${kind.replace('Property', '')}<${names.get(ptr.toUpperCase()) ?? ptr}>`;
    }
    return kind.replace('Property', '');
  };

  for (const full of functions.sort()) {
    if (!full.startsWith('/Script/')) continue;
    const [owner, name, extra] = full.split(':');
    const className = owner.slice(owner.lastIndexOf('.') + 1);
    if (extra !== undefined || !cls.test(className) || (fn && !fn.test(name))) continue;
    const ps = (params.get(full) ?? []).map(p => `${p.name}: ${typeOf(p.kind, p.attrs)} @${p.attrs.get('o') ?? '?'}`);
    console.log(`${className}:${name}(${ps.join(', ')})`);
  }
}

void main();
