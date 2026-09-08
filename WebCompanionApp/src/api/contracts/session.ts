import { z } from 'zod';

import { nullishToNull } from './common';

export const sessionStatusSchema = z.object({
  authenticated: z.boolean(),
  // Swift's synthesized Codable omits nil optionals instead of encoding JSON null.
  deviceID: nullishToNull(z.uuid()),
  authMode: nullishToNull(z.enum(['pairedDevice', 'account'])),
  username: nullishToNull(z.string()),
});

export type SessionStatus = z.infer<typeof sessionStatusSchema>;

export const pairingRequestSchema = z.object({
  pairingToken: z.string().trim().min(1).max(512),
  deviceName: z.string().trim().min(1).max(80),
  clientID: z.string().min(8).max(256),
});

export type PairingRequest = z.infer<typeof pairingRequestSchema>;
