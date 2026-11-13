import assert from 'node:assert/strict';
import { test } from 'node:test';
import { crossSiteWrite, findRoute, type HttpRequest, parseRoute, toResponse } from '../src/http';

const handlers = ['greet', 'http:GET /maps/*', 'http:GET /maps/live', 'http-public:POST /hook', 'http:* /any'];

test('reads routes from handler names', () => {
  assert.deepEqual(parseRoute('http-public:post /hook'), { handler: 'http-public:post /hook', public: true, method: 'POST', path: '/hook' });
  assert.equal(parseRoute('greet'), undefined);
  assert.equal(parseRoute('http:GET nopath'), undefined);
});

test('finds the longest matching route for the method', () => {
  assert.equal(findRoute(handlers, 'GET', '/maps/live')?.path, '/maps/live');
  assert.equal(findRoute(handlers, 'get', '/maps/old/1')?.path, '/maps/*');
  assert.equal(findRoute(handlers, 'GET', '/maps')?.path, '/maps/*');
  assert.equal(findRoute(handlers, 'GET', '/mapsx'), undefined);
  assert.equal(findRoute(handlers, 'GET', '/hook'), undefined);
  assert.equal(findRoute(handlers, 'POST', '/hook')?.public, true);
  assert.equal(findRoute(handlers, 'DELETE', '/any')?.method, '*');
});

test('turns what Lua returned into a response', () => {
  assert.deepEqual(toResponse(undefined), { status: 204 });
  assert.deepEqual(toResponse('hi'), { body: 'hi' });
  assert.deepEqual(toResponse({ count: 2 }), { body: { count: 2 } });
  assert.deepEqual(toResponse({ status: 403, headers: { 'x-a': 1, bad: {} }, body: 'no' }), {
    status: 403, headers: { 'x-a': '1' }, body: 'no',
  });
  assert.deepEqual(toResponse({ status: 42 }), {});
});

test('spots a cross-site write', () => {
  const req = (method: string, origin?: string): HttpRequest => ({
    method, path: '/', query: {}, body: undefined, user: null, ip: '',
    headers: { host: 'omegga.local:8080', ...(origin ? { origin } : {}) },
  });
  assert.equal(crossSiteWrite(req('POST', 'https://evil.example')), true);
  assert.equal(crossSiteWrite(req('POST', 'https://omegga.local:8080')), false);
  assert.equal(crossSiteWrite(req('GET', 'https://evil.example')), false);
  assert.equal(crossSiteWrite(req('POST')), false);
});
