// Prints the content keys and release asset names for a checkout, as
// GITHUB_OUTPUT lines, for CI to decide what to build and publish.
//
//   node tools/runtime-keys.ts [repo dir]
//
// Run by Node directly (type stripping), not built: it's not part of the plugin.
import { runtimeAssets, runtimeKeys } from '../src/runtime-keys.ts';

const keys = runtimeKeys(process.argv[2] ?? '.');
const assets = runtimeAssets(keys);
process.stdout.write(`ue4ss=${keys.ue4ss}\nmod=${keys.mod}\nue4ss_asset=${assets.ue4ss}\nmod_asset=${assets.mod}\n`);
