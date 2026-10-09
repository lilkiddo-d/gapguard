import { NextResponse, type NextRequest } from 'next/server';

/**
 * Optional geoblock. Set NEXT_PUBLIC_BLOCKED_COUNTRIES to a comma-separated list of ISO-3166 alpha-2 codes
 * (e.g. "US,CU,IR,KP,SY"). On Vercel the visitor country comes from the `x-vercel-ip-country` header.
 * Empty / unset = no geoblock. The risk disclosure and the blocked page stay reachable.
 */
const blocked = (process.env.NEXT_PUBLIC_BLOCKED_COUNTRIES || '')
  .split(',')
  .map((c) => c.trim().toUpperCase())
  .filter(Boolean);

export function proxy(request: NextRequest) {
  if (blocked.length === 0) return NextResponse.next();
  const country = (request.headers.get('x-vercel-ip-country') || '').toUpperCase();
  if (country && blocked.includes(country)) {
    return NextResponse.redirect(new URL('/blocked', request.url));
  }
  return NextResponse.next();
}

export const config = {
  matcher: ['/((?!blocked|risk|_next|favicon.ico|icon.svg).*)'],
};
