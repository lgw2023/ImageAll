import { z } from 'zod';

import { requestEmpty, requestJSON } from './client';
import {
  generalSettingsSchema,
  generalSettingsUpdateResponseSchema,
  jobSummarySchema,
  pairedDeviceSchema,
  sourceManagementSchema,
  sourceRequestSchema,
  storageMaintenanceSchema,
  storageRequestSchema,
  type JobAction,
  type SourceManagementAction,
  type StorageMaintenanceAction,
} from './contracts/management';

export function fetchSourceManagement(signal?: AbortSignal) {
  return requestJSON('/v1/source-management', sourceManagementSchema, { signal: signal ?? null });
}

export function submitSourceManagement(action: SourceManagementAction, sourceID?: string) {
  return requestJSON('/v1/source-management/requests', sourceRequestSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), action, sourceID: sourceID ?? null }),
  });
}

export function fetchStorageMaintenance(signal?: AbortSignal) {
  return requestJSON('/v1/storage-maintenance', storageMaintenanceSchema, {
    signal: signal ?? null,
  });
}

export function submitStorageMaintenance(action: StorageMaintenanceAction) {
  return requestJSON('/v1/storage-maintenance/requests', storageRequestSchema, {
    method: 'POST',
    body: JSON.stringify({ operationID: crypto.randomUUID(), action }),
  });
}

export function fetchGeneralSettings(signal?: AbortSignal) {
  return requestJSON('/v1/settings/general', generalSettingsSchema, { signal: signal ?? null });
}

export type GeneralSettingsPatch = {
  modelEnabled?: boolean;
  idleThumbnailPrewarmEnabled?: boolean;
  toolbarDisplayMode?: 'iconOnly' | 'iconAndTitle';
  maxPendingSuggestionsPerTag?: number;
};

export function updateGeneralSettings(patch: GeneralSettingsPatch) {
  return requestJSON('/v1/settings/general', generalSettingsUpdateResponseSchema, {
    method: 'PUT',
    body: JSON.stringify({ operationID: crypto.randomUUID(), ...patch }),
  });
}

export function fetchJobs(signal?: AbortSignal) {
  return requestJSON('/v1/jobs', z.array(jobSummarySchema), { signal: signal ?? null });
}

export function applyJobAction(jobID: string, action: JobAction) {
  return requestJSON(
    `/v1/jobs/${encodeURIComponent(jobID)}/actions`,
    z.object({ jobID: z.uuid() }),
    { method: 'POST', body: JSON.stringify({ action }) },
  );
}

export function fetchPairedDevices(signal?: AbortSignal) {
  return requestJSON('/v1/pairing/devices', z.array(pairedDeviceSchema), {
    signal: signal ?? null,
  });
}

export function revokePairedDevice(deviceID: string) {
  return requestEmpty(`/v1/pairing/devices/${encodeURIComponent(deviceID)}`, {
    method: 'DELETE',
  });
}
