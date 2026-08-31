import { requestJSON } from './client';
import {
  reviewDecisionResponseSchema,
  reviewOverviewSchema,
  reviewQueuePageSchema,
  reviewUndoResponseSchema,
  type ReviewDecisionAction,
} from './contracts/review';

export function fetchReviewOverview(signal?: AbortSignal) {
  return requestJSON('/v1/review/overview?mediaKind=image', reviewOverviewSchema, {
    signal: signal ?? null,
  });
}

export function fetchReviewQueue(tagID: string, cursor: string | null, signal?: AbortSignal) {
  const parameters = new URLSearchParams({ tagID, mediaKind: 'image', limit: '40' });
  if (cursor) parameters.set('cursor', cursor);
  return requestJSON(`/v1/review/queue?${parameters.toString()}`, reviewQueuePageSchema, {
    signal: signal ?? null,
  });
}

export function applyReviewDecision(
  tagID: string,
  assetIDs: string[],
  action: ReviewDecisionAction,
) {
  return requestJSON('/v1/review/decisions/batch', reviewDecisionResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), tagID, assetIDs, action }),
  });
}

export function undoReviewDecision(undoID: string) {
  return requestJSON('/v1/review/decisions/undo', reviewUndoResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), undoID }),
  });
}
