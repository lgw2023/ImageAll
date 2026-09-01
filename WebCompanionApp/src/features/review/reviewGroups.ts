import type { ReviewTagOverview } from '@/api/contracts/review';
import type { TagGroupSummary, TagSummary } from '@/api/contracts/tag';

export const fallbackReviewGroupID = 'a0000000-0000-4000-8000-000000000007';

export type ReviewTagGroup = {
  group: TagGroupSummary;
  tags: ReviewTagOverview[];
};

const fallbackReviewGroup: TagGroupSummary = {
  id: fallbackReviewGroupID,
  displayName: '物品与其他',
  sortOrder: Number.MAX_SAFE_INTEGER,
  isSystem: true,
};

export function buildReviewTagGroups(
  tagCatalog: TagSummary[],
  groupCatalog: TagGroupSummary[],
  overviews: ReviewTagOverview[],
): ReviewTagGroup[] {
  const groupByID = new Map(groupCatalog.map((group) => [group.id, group]));
  const overviewByID = new Map(overviews.map((overview) => [overview.id, overview]));
  const buckets = new Map<string, ReviewTagOverview[]>();

  for (const tag of tagCatalog) {
    const overview = overviewByID.get(tag.id);
    if (!overview || !groupByID.has(tag.groupID)) continue;
    const current = buckets.get(tag.groupID) ?? [];
    current.push(overview);
    buckets.set(tag.groupID, current);
    overviewByID.delete(tag.id);
  }

  const unmatched = [...overviewByID.values()].sort((left, right) => {
    const nameOrder = left.displayName.localeCompare(right.displayName, 'zh-CN', {
      numeric: true,
      sensitivity: 'base',
    });
    return nameOrder || left.id.localeCompare(right.id);
  });
  if (unmatched.length) {
    buckets.set(fallbackReviewGroupID, [
      ...(buckets.get(fallbackReviewGroupID) ?? []),
      ...unmatched,
    ]);
  }

  const orderedGroups = [...groupCatalog].sort(
    (left, right) => left.sortOrder - right.sortOrder || left.id.localeCompare(right.id),
  );
  const result = orderedGroups.flatMap((group) => {
    const tags = buckets.get(group.id) ?? [];
    return tags.length ? [{ group, tags }] : [];
  });

  if (!groupByID.has(fallbackReviewGroupID) && unmatched.length) {
    result.push({ group: fallbackReviewGroup, tags: unmatched });
  }
  return result;
}
