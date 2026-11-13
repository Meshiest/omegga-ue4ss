// Writes the game's names (brick assets, items, entity classes, rule kinds,
// explosions, permissions, emoji...) as LuaLS aliases, from a running server,
// through the UE4SS bridge. Run it after a game update:
//
//   npm run enums -- [bridge socket] [output file]
//
// The socket defaults as for acceptance ($OMEGGA_UE4SS_SOCKET, then
// ./data/UE4SS/bridge.sock); the output defaults to types/enums.lua in this
// repository, the copy editors load with the rest of the API types.
import fs from 'node:fs';
import path from 'node:path';
import { Bridge } from '../src/bridge';

const socket =
  process.argv[2] ??
  process.env.OMEGGA_UE4SS_SOCKET ??
  path.join(process.cwd(), 'data', 'UE4SS', 'bridge.sock');
const out =
  process.argv[3] ?? path.join(__dirname, '..', '..', 'types', 'enums.lua');

async function main() {
  const bridge = new Bridge(socket);
  try {
    const text = await bridge.eval<string>(
      'BR_RELOAD()\nreturn BR.enums.render()',
    );
    const tmp = `${out}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, text.endsWith('\n') ? text : `${text}\n`);
    fs.renameSync(tmp, out);
    const names = text.split('\n').filter(l => l.startsWith('---| ')).length;
    console.log(`wrote ${names} names to ${out}`);
  } finally {
    bridge.close();
  }
}

main().catch(e => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
