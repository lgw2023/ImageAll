import { requestEmpty, requestJSON } from './client';
import { makeBasicAuthorization, setAccountAuthorization } from './credentials';
import {
  pairingRequestSchema,
  sessionStatusSchema,
  type PairingRequest,
  type SessionStatus,
} from './contracts/session';

const CLIENT_ID_KEY = 'imageall.web.client-id';

export function getOrCreateClientID(): string {
  const existing = localStorage.getItem(CLIENT_ID_KEY);
  if (existing && existing.length >= 8 && existing.length <= 256) return existing;
  const next = crypto.randomUUID();
  localStorage.setItem(CLIENT_ID_KEY, next);
  return next;
}

export function defaultDeviceName(): string {
  const userAgent = navigator.userAgent;
  if (/iPhone/i.test(userAgent)) return 'iPhone 网页版';
  if (/iPad/i.test(userAgent)) return 'iPad 网页版';
  if (/Macintosh/i.test(userAgent)) return 'Mac 浏览器';
  return '浏览器网页版';
}

export async function restoreSession(): Promise<SessionStatus> {
  return requestJSON('/web/session', sessionStatusSchema);
}

export async function pairBrowser(input: Omit<PairingRequest, 'clientID'>): Promise<SessionStatus> {
  setAccountAuthorization(null);
  const request = pairingRequestSchema.parse({ ...input, clientID: getOrCreateClientID() });
  return requestJSON('/web/session/pair', sessionStatusSchema, {
    method: 'POST',
    body: JSON.stringify(request),
    canRefresh: false,
  });
}

export async function loginWithAccount(username: string, password: string): Promise<SessionStatus> {
  const authorization = makeBasicAuthorization(username, password);
  setAccountAuthorization(authorization);
  try {
    return await requestJSON('/web/account/login', sessionStatusSchema, {
      method: 'POST',
      body: '{}',
      canRefresh: false,
    });
  } catch (error) {
    setAccountAuthorization(null);
    throw error;
  }
}

export async function logoutSession(): Promise<void> {
  try {
    await requestEmpty('/web/session/logout', { method: 'POST', body: '{}' });
  } finally {
    setAccountAuthorization(null);
  }
}
