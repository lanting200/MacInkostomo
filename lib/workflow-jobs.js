import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { writePrivateFile } from './private-file.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const JOBS_FILE = join(__dirname, '..', 'data', 'workflow-jobs.json');
const TERMINAL_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_TERMINAL_JOBS = 200;

function terminalTime(job) {
  return Date.parse(job?.finishedAt || '') || 0;
}

export function retainWorkflowJobs(jobs, now = Date.now()) {
  const active = jobs.filter(job => job && !job.finishedAt);
  const terminal = jobs
    .filter(job => job?.finishedAt && now - terminalTime(job) <= TERMINAL_TTL_MS)
    .sort((a, b) => terminalTime(b) - terminalTime(a))
    .slice(0, MAX_TERMINAL_JOBS);
  return [...active, ...terminal];
}

function workflowJobsError(file, message, cause) {
  const err = new Error(`${message}: ${file}`);
  err.code = 'WORKFLOW_JOBS_INVALID';
  err.statusCode = 503;
  err.cause = cause;
  return err;
}

function backUpInvalidJobs(file, raw) {
  try {
    const backup = `${file}.corrupt-${Date.now()}`;
    writeFileSync(backup, raw, { encoding: 'utf-8', mode: 0o600 });
    chmodSync(backup, 0o600);
    return backup;
  } catch {
    return '';
  }
}

export function loadWorkflowJobs(file = JOBS_FILE) {
  if (!existsSync(file)) return { generationJobs: [], creationJobs: [] };
  let raw;
  try {
    chmodSync(file, 0o600);
    raw = readFileSync(file, 'utf-8');
  } catch (err) {
    throw workflowJobsError(file, `任务状态文件读取失败：${err.message}`, err);
  }

  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('根节点必须是对象');
    }
    if (!Array.isArray(parsed.generationJobs) || !Array.isArray(parsed.creationJobs)) {
      throw new Error('generationJobs 和 creationJobs 必须是数组');
    }
    return {
      generationJobs: parsed.generationJobs,
      creationJobs: parsed.creationJobs,
    };
  } catch (err) {
    const backup = backUpInvalidJobs(file, raw);
    const suffix = backup ? `，原始内容已备份到 ${backup}` : '，原始文件保持未改动';
    throw workflowJobsError(file, `任务状态文件损坏${suffix}：${err.message}`, err);
  }
}

export function saveWorkflowJobs(generationJobs, creationJobs, file = JOBS_FILE) {
  mkdirSync(dirname(file), { recursive: true });
  const payload = {
    version: 1,
    updatedAt: new Date().toISOString(),
    generationJobs: retainWorkflowJobs(Array.from(generationJobs || [])),
    creationJobs: retainWorkflowJobs(Array.from(creationJobs || [])),
  };
  writePrivateFile(file, JSON.stringify(payload, null, 2));
  return payload;
}
