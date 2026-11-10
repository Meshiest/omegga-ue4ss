// Example omegga plugin (unsafe format) using the ue4ss plugin's interop, with a
// UE4SS mod of its own in mods/InteropDemo. Copy the folder into plugins/ next
// to ue4ss to try it; it runs a short self-test once the game is up and logs
// everything with a [demo] prefix.
const NAME = 'ue4ss-interop-demo';
const sleep = ms => new Promise(r => setTimeout(r, ms));

module.exports = class InteropDemo {
  constructor(omegga) {
    this.omegga = omegga;
  }

  async init() {
    this.ue4ss = await this.omegga.getPlugin('ue4ss');
    // Lua events arrive as pluginEvent('ue4ss:<event>', from, data) ...
    await this.ue4ss.emitPlugin('subscribe', NAME, '*');
    // ... and as omegga events
    this.omegga.on('ue4ss:hello', data => console.log('[demo] omegga event ue4ss:hello', JSON.stringify(data)));
    void this.selftest();
    return { registeredCommands: [] };
  }

  async call(name, ...args) {
    return this.ue4ss.emitPlugin('call', name, ...args);
  }

  async selftest() {
    // the mod registers its handlers once the game has started UE4SS
    let greeting;
    for (let i = 0; i < 120; i++) {
      greeting = await this.call('greet', 'omegga');
      if (greeting.ok) break;
      await sleep(1000);
    }
    console.log('[demo] greet ->', JSON.stringify(greeting));
    // the handlers answer before the map has loaded; world access must wait
    for (let i = 0; i < 120 && !(await this.call('ready')).result; i++) await sleep(1000);
    console.log('[demo] add_via_js ->', JSON.stringify(await this.call('add_via_js', 2, 3)));
    console.log('[demo] build_lamp ->', JSON.stringify(await this.call('build_lamp', 0, 1200)));
    await sleep(500);
    console.log('[demo] set_lamp(true, true) ->', JSON.stringify(await this.call('set_lamp', true, true)));
    await sleep(500);
    console.log('[demo] set_lamp(true, false) ->', JSON.stringify(await this.call('set_lamp', true, false)));
    await sleep(500);
    console.log('[demo] selftest done');
  }

  async pluginEvent(event, _from, ...args) {
    if (event.startsWith('ue4ss:')) {
      console.log('[demo] got', event, JSON.stringify(args[0]));
      return;
    }
    // Lua -> JS: Omegga.call('ue4ss-interop-demo', 'add', { 2, 3 }, callback)
    if (event === 'add') return args.reduce((a, b) => a + b, 0);
  }

  async stop() {}
};
