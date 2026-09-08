import { describe, expect, it } from 'vitest';

import { pairingRequestSchema, sessionStatusSchema } from './session';

describe('session contracts', () => {
  it('decodes omitted Swift optional fields for account, pairing, and legacy responses', () => {
    expect(
      sessionStatusSchema.parse({
        authenticated: true,
        authMode: 'account',
        username: 'reader',
      }),
    ).toEqual({ authenticated: true, authMode: 'account', username: 'reader', deviceID: null });
    expect(
      sessionStatusSchema.parse({
        authenticated: true,
        authMode: 'pairedDevice',
        deviceID: '7dd77e6b-8c95-4f5a-90e7-cbc61f3e24c4',
      }).username,
    ).toBeNull();
    expect(sessionStatusSchema.parse({ authenticated: true })).toEqual({
      authenticated: true,
      deviceID: null,
      authMode: null,
      username: null,
    });
  });

  it('accepts the paired-device status encoded by Swift', () => {
    expect(
      sessionStatusSchema.parse({
        authenticated: true,
        deviceID: '7dd77e6b-8c95-4f5a-90e7-cbc61f3e24c4',
        authMode: 'pairedDevice',
        username: null,
      }),
    ).toMatchObject({ authenticated: true, authMode: 'pairedDevice' });
  });

  it('rejects malformed identifiers and unknown authentication modes', () => {
    expect(() =>
      sessionStatusSchema.parse({
        authenticated: true,
        deviceID: 'not-a-uuid',
        authMode: 'rememberedPassword',
        username: null,
      }),
    ).toThrow();
  });

  it('enforces the Host pairing length limits', () => {
    expect(() =>
      pairingRequestSchema.parse({ pairingToken: 'token', deviceName: '', clientID: 'short' }),
    ).toThrow();
  });
});
