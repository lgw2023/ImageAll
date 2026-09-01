import { useCallback, useState } from 'react';

export const collapsedTagGroupsStorageKey = 'imageall-web-v2-collapsed-tag-groups';

function loadCollapsedGroups() {
  try {
    const stored = localStorage.getItem(collapsedTagGroupsStorageKey);
    const parsed: unknown = stored ? JSON.parse(stored) : [];
    return new Set(Array.isArray(parsed) ? parsed.filter((item) => typeof item === 'string') : []);
  } catch {
    return new Set<string>();
  }
}

export function useCollapsedTagGroups() {
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(loadCollapsedGroups);
  const toggleGroup = useCallback((groupID: string) => {
    setCollapsedGroups((current) => {
      const next = new Set(current);
      if (next.has(groupID)) next.delete(groupID);
      else next.add(groupID);
      try {
        localStorage.setItem(collapsedTagGroupsStorageKey, JSON.stringify([...next]));
      } catch {
        // A blocked preference store must not make the in-memory disclosure unusable.
      }
      return next;
    });
  }, []);
  return { collapsedGroups, toggleGroup };
}
