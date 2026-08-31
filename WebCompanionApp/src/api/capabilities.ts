import { requestJSON } from './client';
import { capabilitiesSchema, type Capabilities } from './contracts/capabilities';

export function fetchCapabilities(signal?: AbortSignal): Promise<Capabilities> {
  return signal
    ? requestJSON('/v1/capabilities', capabilitiesSchema, { signal })
    : requestJSON('/v1/capabilities', capabilitiesSchema);
}
