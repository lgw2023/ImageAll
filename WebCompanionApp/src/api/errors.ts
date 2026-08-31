import { z } from 'zod';

const remoteProblemSchema = z.object({
  code: z.string().optional(),
  message: z.string().optional(),
  details: z.unknown().optional(),
  retryable: z.boolean().optional(),
});

export class APIError extends Error {
  readonly status: number;
  readonly code: string | undefined;
  readonly retryable: boolean;

  constructor(status: number, message: string, code?: string, retryable = false) {
    super(message);
    this.name = 'APIError';
    this.status = status;
    this.code = code;
    this.retryable = retryable;
  }
}

export async function errorFromResponse(response: Response): Promise<APIError> {
  const contentType = response.headers.get('content-type') ?? '';
  if (contentType.includes('application/json')) {
    const result = remoteProblemSchema.safeParse(await response.json().catch(() => null));
    if (result.success) {
      return new APIError(
        response.status,
        result.data.message ?? `请求失败（${String(response.status)}）`,
        result.data.code,
        result.data.retryable ?? response.status >= 500,
      );
    }
  }
  return new APIError(
    response.status,
    `请求失败（${String(response.status)}）`,
    undefined,
    response.status >= 500,
  );
}

export function errorMessage(error: unknown): string {
  if (error instanceof APIError) return error.message;
  if (error instanceof Error && error.message) return error.message;
  return '无法完成请求';
}
