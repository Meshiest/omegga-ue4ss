/**
 * HTTP routes served by Lua mods (`Omegga.route`), reached through omegga's
 * plugin routes as `/api/v1/plugin/ue4ss/<path>`. Each route is a Lua handler
 * registered under a name that carries its method, path and whether it needs a
 * web UI login: `http:GET /players`, `http-public:POST /hook/*`.
 */

/** A request as omegga hands it to a plugin's `http` method. */
export interface HttpRequest {
  method: string;
  path: string;
  query: Record<string, string | string[]>;
  headers: Record<string, string>;
  body: unknown;
  user: { id: string; username: string } | null;
  ip: string;
}

export interface HttpResponse {
  status?: number;
  headers?: Record<string, string>;
  body?: unknown;
}

export interface Route {
  handler: string;
  method: string;
  path: string;
  public: boolean;
}

const NAME = /^http(-public)?:(\S+) (\/\S*)$/;

/** The route a handler name describes, or undefined for other handlers. */
export function parseRoute(handler: string): Route | undefined {
  const m = NAME.exec(handler);
  if (!m) return undefined;
  return { handler, public: m[1] !== undefined, method: m[2].toUpperCase(), path: m[3] };
}

// `/a/*` matches `/a` and everything below it; anything else matches exactly
function matches(pattern: string, path: string) {
  if (pattern.endsWith('/*')) {
    const base = pattern.slice(0, -2);
    return path === base || path.startsWith(base + '/');
  }
  return pattern === path;
}

/**
 * The route for a request among the registered handler names: the method must
 * match (or the route's be `*`), and of several matching paths the longest
 * pattern wins, so `/maps/live` beats `/maps/*`.
 */
export function findRoute(handlers: Iterable<string>, method: string, path: string): Route | undefined {
  let best: Route | undefined;
  for (const name of handlers) {
    const route = parseRoute(name);
    if (!route || (route.method !== '*' && route.method !== method.toUpperCase())) continue;
    if (!matches(route.path, path)) continue;
    if (!best || route.path.length > best.path.length) best = route;
  }
  return best;
}

/**
 * Whether a logged-in browser sent a state-changing request from another
 * site's page. omegga checks this itself only for plugins that need a login;
 * this plugin is public to omegga and checks per route.
 */
export function crossSiteWrite(request: HttpRequest) {
  if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(request.method)) return false;
  const origin = request.headers.origin;
  if (!origin) return false;
  try {
    return new URL(origin).host !== request.headers.host;
  } catch {
    return true;
  }
}

/**
 * What a Lua route returned, as a response: a string or number is the body;
 * a table with `status`, `headers` or `body` is a response, any other table a
 * JSON body; nothing at all is an empty 204.
 */
export function toResponse(result: unknown): HttpResponse {
  if (result === undefined || result === null) return { status: 204 };
  if (typeof result === 'string' || typeof result === 'number' || typeof result === 'boolean')
    return { body: String(result) };
  if (typeof result !== 'object' || Array.isArray(result)) return { body: result };
  if (!('status' in result || 'headers' in result || 'body' in result)) return { body: result };
  const out: HttpResponse = {};
  const status = 'status' in result ? result.status : undefined;
  if (typeof status === 'number' && Number.isInteger(status) && status >= 100 && status <= 599) out.status = status;
  const headers = 'headers' in result ? result.headers : undefined;
  if (typeof headers === 'object' && headers !== null && !Array.isArray(headers)) {
    out.headers = {};
    for (const [k, v] of Object.entries(headers)) if (typeof v === 'string' || typeof v === 'number') out.headers[k] = String(v);
  }
  if ('body' in result) out.body = result.body;
  return out;
}
