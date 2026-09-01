import type { ReviewTagOverview } from '@/api/contracts/review';
import type { TagGroupSummary, TagSummary } from '@/api/contracts/tag';
import { groupTagsByHostCatalog } from '@/features/tags/tagGrouping';

export type ReviewTagGroup = {
  group: TagGroupSummary;
  tags: ReviewTagOverview[];
};

export function buildReviewTagGroups(
  tagCatalog: TagSummary[],
  groupCatalog: TagGroupSummary[],
  overviews: ReviewTagOverview[],
): ReviewTagGroup[] {
  return groupTagsByHostCatalog(tagCatalog, groupCatalog, overviews, (overview) => overview.id);
}
