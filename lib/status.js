// Shared chapter status values. The frontend (public/app.js) keeps its own
// string literals for the same set — keep them in sync when changing here.
export const STATUS = {
  PENDING_REVIEW: 'pending_review',
  APPROVED: 'approved',
  REVISION_REQUESTED: 'revision_requested',
  REVISION_FAILED: 'revision_failed',
  REJECTED: 'rejected',
  PUBLISHED: 'published',
};

// Word count for Chinese text: number of non-whitespace characters.
export function wordCount(content) {
  return (content || '').replace(/\s/g, '').length;
}
