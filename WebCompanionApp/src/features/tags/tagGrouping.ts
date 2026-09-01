import type { TagGroupSummary, TagSummary } from '@/api/contracts/tag';

export const fallbackTagGroupID = 'a0000000-0000-4000-8000-000000000007';

const fallbackTagGroup: TagGroupSummary = {
  id: fallbackTagGroupID,
  displayName: '物品与其他',
  sortOrder: Number.MAX_SAFE_INTEGER,
  isSystem: true,
};

export type HostTagGroup<T> = {
  group: TagGroupSummary;
  tags: T[];
};

export function groupTagsByHostCatalog<T extends { displayName: string }>(
  tagCatalog: TagSummary[],
  groupCatalog: TagGroupSummary[],
  items: T[],
  itemID: (item: T) => string,
): HostTagGroup<T>[] {
  const groupByID = new Map(groupCatalog.map((group) => [group.id, group]));
  const itemByID = new Map(items.map((item) => [itemID(item), item]));
  const buckets = new Map<string, T[]>();

  for (const tag of tagCatalog) {
    const item = itemByID.get(tag.id);
    if (!item || !groupByID.has(tag.groupID)) continue;
    const current = buckets.get(tag.groupID) ?? [];
    current.push(item);
    buckets.set(tag.groupID, current);
    itemByID.delete(tag.id);
  }

  const unmatched = [...itemByID.values()].sort((left, right) => {
    const nameOrder = left.displayName.localeCompare(right.displayName, 'zh-CN', {
      numeric: true,
      sensitivity: 'base',
    });
    return nameOrder || itemID(left).localeCompare(itemID(right));
  });
  if (unmatched.length) {
    buckets.set(fallbackTagGroupID, [...(buckets.get(fallbackTagGroupID) ?? []), ...unmatched]);
  }

  const orderedGroups = [...groupCatalog].sort(
    (left, right) => left.sortOrder - right.sortOrder || left.id.localeCompare(right.id),
  );
  const result = orderedGroups.flatMap((group) => {
    const tags = buckets.get(group.id) ?? [];
    return tags.length ? [{ group, tags }] : [];
  });

  if (!groupByID.has(fallbackTagGroupID) && unmatched.length) {
    result.push({ group: fallbackTagGroup, tags: unmatched });
  }
  return result;
}
