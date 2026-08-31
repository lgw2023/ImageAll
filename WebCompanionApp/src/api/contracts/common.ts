import { z } from 'zod';

export const uuidSchema = z.uuid();

export function nullishToNull<T extends z.ZodType>(schema: T) {
  return schema.nullish().transform((value) => value ?? null);
}
