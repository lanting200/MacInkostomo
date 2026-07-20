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

function stripMarkdownMetadata(content) {
  const lines = String(content || '').replace(/\r\n/g, '\n').replace(/^\uFEFF/, '').split('\n');
  const prose = [];
  let index = 0;
  if (lines[index]?.trim() === '---') {
    index += 1;
    while (index < lines.length && lines[index]?.trim() !== '---') index += 1;
    if (index < lines.length) index += 1;
  }
  let inFence = false;
  for (; index < lines.length; index += 1) {
    const line = lines[index] || '';
    const trimmed = line.trim();
    if (/^(```|~~~)/.test(trimmed)) {
      inFence = !inFence;
      continue;
    }
    if (inFence || /^#{1,6}\s+/.test(trimmed) || trimmed === '---' || trimmed === '...') continue;
    prose.push(line);
  }
  return prose.join('\n');
}

export function chapterLength(content, language = 'zh') {
  const prose = stripMarkdownMetadata(content);
  if (language === 'en') {
    return prose.match(/[A-Za-z0-9]+(?:'[A-Za-z0-9]+)?/g)?.length || 0;
  }
  return prose.replace(/\s+/g, '').length;
}
