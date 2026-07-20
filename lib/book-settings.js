import { readFileSync, writeFileSync, readdirSync, existsSync } from 'fs';
import { join, relative, resolve, sep } from 'path';
import { assertBookId, PATHS } from './paths.js';

// InkOS stores book settings (worldbuilding, characters, foreshadowing hooks,
// outline, progression) as markdown files under
//   ./book/books/<bookId>/story/
// InkOS reads these itself when writing new chapters, so the panel just edits
// the files directly — no separate store. Filenames are NOT hardcoded (they
// vary across inkos versions); we list whatever .md exists.

const BOOKS_DIR = resolve(PATHS.BOOKS_DIR, 'books');

const STORY_DIR = (bookId) => join(BOOKS_DIR, assertBookId(bookId), 'story');

const SETTINGS_GROUPS = [
  { id: 'direction', title: '创作方向', order: 10 },
  { id: 'canon', title: '世界与卷纲', order: 20 },
  { id: 'runtime', title: '当前写作状态', order: 30 },
  { id: 'characters', title: '角色档案', order: 40 },
  { id: 'other', title: '其他设定', order: 90 },
];

const FILE_METADATA = {
  'author_intent.md': { group: 'direction', order: 10, title: '创作简报', description: '全书题材、主角定位、核心卖点与长期写作要求。修改会影响后续所有章节。' },
  'brief.md': { group: 'direction', order: 20, title: '项目简介', description: '书籍的简要定位与创建时的基础要求。' },
  'current_focus.md': { group: 'direction', order: 30, title: '当前聚焦', description: '接下来 1-3 章的优先目标与取舍。用于防止新章节跑偏。' },
  'book_rules.md': { group: 'canon', order: 10, title: '硬规则', description: '不能违背的人设、能力边界、设定禁忌和叙事规则。' },
  'story_bible.md': { group: 'canon', order: 20, title: '故事圣经', description: '世界观、力量体系、主线秘密与长期一致性依据。' },
  'outline/story_frame.md': { group: 'canon', order: 30, title: '故事基石', description: '主题、核心冲突、前后台故事和终局方向。' },
  'outline/volume_map.md': { group: 'canon', order: 40, title: '分卷地图', description: '每卷目标、章节范围、情绪曲线和阶段回收安排。' },
  'style_guide.md': { group: 'canon', order: 50, title: '文风指南', description: '叙事视角、语言密度、节奏与表达边界。' },
  'current_state.md': { group: 'runtime', order: 10, title: '当前状态', description: '角色位置、伤势、资源、限制、敌我与下一步目标。' },
  'pending_hooks.md': { group: 'runtime', order: 20, title: '伏笔池', description: '已开伏笔、读者承诺、最近进展与后续回收方向。' },
  'chapter_summaries.md': { group: 'runtime', order: 30, title: '章节摘要', description: '已写章节的关键事件、状态变化和伏笔动态汇总。' },
  'particle_ledger.md': { group: 'runtime', order: 40, title: '资源账本', description: '符箓、材料、证物、伤势与消耗的可追溯记录。' },
  'object_ledger.md': { group: 'runtime', order: 45, title: '持久对象账本', description: '跨章节保存重要物品的稳定身份、材质、刻字、持有者、位置、状态和关联伏笔。通常由 InkOS 自动维护。', managed: true },
  'character_matrix.md': { group: 'runtime', order: 50, title: '人物关系', description: '主要人物的关系、立场、知情范围与当前变化。' },
  'emotional_arcs.md': { group: 'runtime', order: 60, title: '情感弧线', description: '角色关系与情绪节奏的阶段推进记录。' },
  'subplot_board.md': { group: 'runtime', order: 70, title: '支线进度', description: '支线的当前阶段、关联人物与回收安排。' },
  'audit_drift.md': { group: 'runtime', order: 80, title: '审计纠偏', description: '最近一次审核给下一章的结构提醒。通常由 InkOS 自动维护。', managed: true },
};

function listMarkdownFiles(dir) {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const name of readdirSync(dir, { withFileTypes: true })) {
    if (name.isFile() && name.name.endsWith('.md')) {
      out.push(name.name);
    }
  }
  return out.sort();
}

// Recursively list .md files under story/, including subdirs like outline/.
function listMarkdownFilesRecursive(dir, base = '') {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const rel = base ? `${base}/${e.name}` : e.name;
    if (e.isDirectory()) {
      out.push(...listMarkdownFilesRecursive(join(dir, e.name), rel));
    } else if (e.isFile() && e.name.endsWith('.md')) {
      out.push(rel);
    }
  }
  return out.sort();
}

function isEditableStoryFile(relPath) {
  const normalized = String(relPath || '').split(sep).join('/');
  const root = normalized.split('/')[0];
  return normalized.endsWith('.md') && !['runtime', 'snapshots', 'state'].includes(root);
}

function resolveEditableStoryFile(bookId, relPath) {
  const dir = STORY_DIR(bookId);
  const requestedPath = String(relPath || '');
  if (!requestedPath) throw new Error('需要设定文件路径');

  const full = resolve(dir, requestedPath);
  const normalizedPath = relative(dir, full).split(sep).join('/');
  if (!normalizedPath || normalizedPath === '..' || normalizedPath.startsWith('../')) {
    throw new Error('非法路径');
  }
  if (!isEditableStoryFile(normalizedPath)) {
    throw new Error('只能读取或修改可维护的 Markdown 设定文件');
  }
  return { dir, full, path: normalizedPath };
}

function fileMetadata(relPath) {
  const known = FILE_METADATA[relPath];
  if (known) return known;
  if (relPath.startsWith('roles/')) {
    const name = relPath.split('/').pop().replace(/\.md$/, '');
    return {
      group: 'characters',
      order: 100,
      title: `${name}角色卡`,
      description: '角色的背景、动机、关系、能力边界与当前状态。',
    };
  }
  if (relPath.startsWith('outline/')) {
    return {
      group: 'canon',
      order: 90,
      title: relPath.split('/').pop().replace(/\.md$/, ''),
      description: '分卷或故事规划文件，影响后续章节的方向与节奏。',
    };
  }
  return {
    group: 'other',
    order: 999,
    title: relPath.replace(/\.md$/, ''),
    description: 'InkOS 书籍设定文件。修改前请确认它与当前剧情和其他设定一致。',
  };
}

export function getBookSettings(bookId) {
  const dir = STORY_DIR(bookId);
  const groupsById = new Map(SETTINGS_GROUPS.map(group => [group.id, group]));
  const files = listMarkdownFilesRecursive(dir)
    .filter(isEditableStoryFile)
    .map(path => {
      const meta = fileMetadata(path);
      const group = groupsById.get(meta.group) || groupsById.get('other');
      return {
        path,
        title: meta.title,
        description: meta.description,
        group: group.id,
        groupTitle: group.title,
        groupOrder: group.order,
        order: meta.order,
        managed: Boolean(meta.managed),
      };
    })
    .sort((a, b) => a.groupOrder - b.groupOrder || a.order - b.order || a.path.localeCompare(b.path, 'zh-CN'));
  return {
    storyDir: dir,
    groups: SETTINGS_GROUPS,
    files,
  };
}

export function getBookSetting(bookId, relPath) {
  const { full } = resolveEditableStoryFile(bookId, relPath);
  if (!existsSync(full)) return null;
  return readFileSync(full, 'utf-8');
}

export function saveBookSetting(bookId, relPath, content) {
  if (typeof content !== 'string') throw new Error('设定文件内容必须为文本');
  const { full, path } = resolveEditableStoryFile(bookId, relPath);
  if (!existsSync(full)) throw new Error('设定文件不存在或已被移除');
  writeFileSync(full, content, 'utf-8');
  return { ok: true, path, size: content.length };
}
