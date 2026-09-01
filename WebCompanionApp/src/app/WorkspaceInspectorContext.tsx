import { createContext, useContext, useEffect, useId, type ReactNode } from 'react';

export type WorkspaceInspectorDescriptor = {
  eyebrow: string;
  title: string;
  content: ReactNode;
};

export type WorkspaceInspectorRegistry = {
  publish: (ownerID: string, descriptor: WorkspaceInspectorDescriptor) => void;
  clear: (ownerID: string) => void;
};

export const WorkspaceInspectorContext = createContext<WorkspaceInspectorRegistry | null>(null);

export function useWorkspaceInspector(descriptor: WorkspaceInspectorDescriptor | null) {
  const registry = useContext(WorkspaceInspectorContext);
  const ownerID = useId();

  useEffect(() => {
    if (!registry) return;
    if (descriptor) registry.publish(ownerID, descriptor);
    else registry.clear(ownerID);
  }, [descriptor, ownerID, registry]);

  useEffect(
    () => () => {
      registry?.clear(ownerID);
    },
    [ownerID, registry],
  );
}
