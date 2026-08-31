import { z } from 'zod';

import { requestJSON } from './client';
import {
  batchTagDecisionResponseSchema,
  tagSelectionAggregateSchema,
  tagSummarySchema,
  undoTagDecisionResponseSchema,
  type BatchTagDecisionResponse,
  type TagDecisionAction,
  type TagSelectionAggregate,
  type TagSummary,
} from './contracts/tag';

export async function fetchTags(signal?: AbortSignal): Promise<TagSummary[]> {
  return requestJSON('/v1/tags', z.array(tagSummarySchema), { signal: signal ?? null });
}

export async function fetchTagSelection(
  tagIDs: string[],
  assetIDs: string[],
  signal?: AbortSignal,
): Promise<TagSelectionAggregate[]> {
  return requestJSON('/v1/tags/selection', z.array(tagSelectionAggregateSchema), {
    method: 'POST',
    body: JSON.stringify({ tagIDs, assetIDs }),
    signal: signal ?? null,
  });
}

export async function applyTagDecision(
  tagID: string,
  assetIDs: string[],
  action: TagDecisionAction,
): Promise<BatchTagDecisionResponse> {
  return requestJSON('/v1/tag-decisions/batch', batchTagDecisionResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), tagID, assetIDs, action }),
  });
}

export async function undoTagDecision(undoID: string) {
  return requestJSON('/v1/tag-decisions/undo', undoTagDecisionResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), undoID }),
  });
}
