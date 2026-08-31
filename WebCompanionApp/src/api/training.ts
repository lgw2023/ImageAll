import { z } from 'zod';

import { requestJSON } from './client';
import {
  embeddingPreparationActionResponseSchema,
  embeddingPreparationResponseSchema,
  embeddingPreparationSnapshotSchema,
  librarySuggestionResponseSchema,
  librarySuggestionSnapshotSchema,
  sampleSuggestionActionResponseSchema,
  sampleSuggestionResponseSchema,
  sampleSuggestionSnapshotSchema,
  tagLibrarySuggestionActionResponseSchema,
  tagLibrarySuggestionResponseSchema,
  tagLibrarySuggestionSnapshotSchema,
  trainingActivityActionResponseSchema,
  trainingActivitySchema,
  trainingLaunchResponseSchema,
  trainingSetupSchema,
  trainingWorkspaceSchema,
  type TrainingMethod,
} from './contracts/training';
import type { AssetMediaKind } from './contracts/asset';

function mediaQuery(mediaKind: AssetMediaKind) {
  return new URLSearchParams({ mediaKind }).toString();
}

export function fetchTrainingSetup(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(`/v1/training/setup?${mediaQuery(mediaKind)}`, trainingSetupSchema, {
    signal: signal ?? null,
  });
}

export function fetchTrainingWorkspace(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(`/v1/training/workspace?${mediaQuery(mediaKind)}`, trainingWorkspaceSchema, {
    signal: signal ?? null,
  });
}

export function fetchTrainingActivities(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(
    `/v1/training/activities?${mediaQuery(mediaKind)}`,
    z.array(trainingActivitySchema),
    {
      signal: signal ?? null,
    },
  );
}

export function launchTraining(input: {
  mediaKind: AssetMediaKind;
  method: TrainingMethod;
  tagIDs: string[];
  sourceIDs: string[];
  assetIDs?: string[];
}) {
  return requestJSON('/v1/training/launch', trainingLaunchResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), assetIDs: [], ...input }),
  });
}

export function cancelTraining(operationID: string) {
  return requestJSON(
    `/v1/training/activities/${operationID}/actions`,
    trainingActivityActionResponseSchema,
    { method: 'POST', body: JSON.stringify({ action: 'cancel' }) },
  );
}

export function fetchEmbeddingPreparation(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(
    `/v1/embedding-preparation?${mediaQuery(mediaKind)}`,
    embeddingPreparationSnapshotSchema,
    { signal: signal ?? null },
  );
}

export function prepareEmbeddings(mediaKind: AssetMediaKind, assetIDs: string[]) {
  return requestJSON('/v1/embedding-preparation/requests', embeddingPreparationResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), mediaKind, assetIDs }),
  });
}

export function cancelEmbeddingPreparation(operationID: string) {
  return requestJSON(
    `/v1/embedding-preparation/requests/${operationID}/actions`,
    embeddingPreparationActionResponseSchema,
    { method: 'POST', body: JSON.stringify({ action: 'cancel' }) },
  );
}

export function fetchSampleSuggestions(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(
    `/v1/sample-suggestions?${mediaQuery(mediaKind)}`,
    sampleSuggestionSnapshotSchema,
    { signal: signal ?? null },
  );
}

export function generateSampleSuggestions(mediaKind: AssetMediaKind, sourceIDs: string[] | null) {
  return requestJSON('/v1/sample-suggestions/requests', sampleSuggestionResponseSchema, {
    method: 'POST',
    body: JSON.stringify({
      operationID: crypto.randomUUID(),
      mediaKind,
      assetIDs: [],
      sourceIDs,
    }),
  });
}

export function cancelSampleSuggestions(operationID: string) {
  return requestJSON(
    `/v1/sample-suggestions/requests/${operationID}/actions`,
    sampleSuggestionActionResponseSchema,
    { method: 'POST', body: JSON.stringify({ action: 'cancel' }) },
  );
}

export function fetchLibrarySuggestions(
  mediaKind: AssetMediaKind,
  refreshServiceHealth = false,
  signal?: AbortSignal,
) {
  const parameters = new URLSearchParams({ mediaKind });
  if (refreshServiceHealth) parameters.set('refreshServiceHealth', '1');
  return requestJSON(`/v1/library-suggestions?${parameters}`, librarySuggestionSnapshotSchema, {
    signal: signal ?? null,
  });
}

export function generateLibrarySuggestions(
  mediaKind: AssetMediaKind,
  track: 'standard' | 'personal',
  sourceIDs: string[] | null,
) {
  return requestJSON('/v1/library-suggestions/requests', librarySuggestionResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), mediaKind, track, sourceIDs }),
  });
}

export function fetchTagLibrarySuggestions(mediaKind: AssetMediaKind, signal?: AbortSignal) {
  return requestJSON(
    `/v1/tag-library-suggestions?${mediaQuery(mediaKind)}`,
    tagLibrarySuggestionSnapshotSchema,
    { signal: signal ?? null },
  );
}

export function generateTagLibrarySuggestions(input: {
  mediaKind: AssetMediaKind;
  method: 'personalCentroid' | 'personalAdamW';
  tagID: string;
  sourceIDs: string[];
}) {
  return requestJSON('/v1/tag-library-suggestions/requests', tagLibrarySuggestionResponseSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), ...input }),
  });
}

export function cancelTagLibrarySuggestions(operationID: string) {
  return requestJSON(
    `/v1/tag-library-suggestions/requests/${operationID}/actions`,
    tagLibrarySuggestionActionResponseSchema,
    { method: 'POST', body: JSON.stringify({ action: 'cancel' }) },
  );
}
