import { z } from 'zod';

export const sessionStatusSchema = z.object({
  authenticated: z.boolean(),
  deviceID: z.uuid().nullable(),
  authMode: z.enum(['pairedDevice', 'account']).nullable(),
  username: z.string().nullable(),
});

export type SessionStatus = z.infer<typeof sessionStatusSchema>;

export const pairingRequestSchema = z.object({
  pairingToken: z.string().trim().min(1).max(512),
  deviceName: z.string().trim().min(1).max(80),
  clientID: z.string().min(8).max(256),
});

export type PairingRequest = z.infer<typeof pairingRequestSchema>;
