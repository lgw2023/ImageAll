import { z } from 'zod';

import { requestJSON } from './client';
import {
  batchTagDecisionResponseSchema,
  createTagAndApplyResponseSchema,
  installPresetTagsResponseSchema,
  tagGroupMutationResponseSchema,
  tagGroupSummarySchema,
  tagMutationResponseSchema,
  tagSelectionAggregateSchema,
  tagSummarySchema,
  undoTagDecisionResponseSchema,
  type BatchTagDecisionResponse,
  type CreateTagAndApplyResponse,
  type TagDecisionAction,
  type TagSelectionAggregate,
  type TagSummary,
} from './contracts/tag';

export async function fetchTags(signal?: AbortSignal): Promise<TagSummary[]> {
  return requestJSON('/v1/tags', z.array(tagSummarySchema), { signal: signal ?? null });
}

export function fetchTagGroups(signal?: AbortSignal) {
  return requestJSON('/v1/tag-groups', z.array(tagGroupSummarySchema), {
    signal: signal ?? null,
  });
}

export function installPresetTags() {
  return requestJSON('/v1/tags/install-presets', installPresetTagsResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID() }),
  });
}

export function createTagGroup(name: string) {
  return requestJSON('/v1/tag-groups', tagGroupMutationResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), name }),
  });
}

export function renameTagGroup(groupID: string, name: string) {
  return requestJSON(
    `/v1/tag-groups/${encodeURIComponent(groupID)}/rename`,
    tagGroupMutationResponseSchema,
    {
      method: 'POST',
      body: JSON.stringify({ operationID: crypto.randomUUID(), name }),
    },
  );
}

export function deleteTagGroup(groupID: string) {
  return requestJSON(
    `/v1/tag-groups/${encodeURIComponent(groupID)}/delete`,
    tagGroupMutationResponseSchema,
    {
      method: 'POST',
      body: JSON.stringify({ operationID: crypto.randomUUID() }),
    },
  );
}

export function renameTag(tagID: string, name: string) {
  return requestJSON(`/v1/tags/${encodeURIComponent(tagID)}/rename`, tagMutationResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), name }),
  });
}

export function moveTag(tagID: string, groupID: string) {
  return requestJSON(`/v1/tags/${encodeURIComponent(tagID)}/move`, tagMutationResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), groupID }),
  });
}

export function archiveTag(tagID: string) {
  return requestJSON(`/v1/tags/${encodeURIComponent(tagID)}/archive`, tagMutationResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID() }),
  });
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

export function createTagAndApply(
  name: string,
  assetIDs: string[],
  operationID: string,
): Promise<CreateTagAndApplyResponse> {
  return requestJSON('/v1/tags/create-and-apply', createTagAndApplyResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID, name, assetIDs }),
  });
}

export async function undoTagDecision(undoID: string) {
  return requestJSON('/v1/tag-decisions/undo', undoTagDecisionResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), undoID }),
  });
}
