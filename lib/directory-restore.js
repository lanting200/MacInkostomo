import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync, chmodSync } from 'fs';
import { dirname, join } from 'path';

export function copyDirectoryStrict(sourceDir, destinationDir, files = []) {
  if (!existsSync(sourceDir)) return files;
  mkdirSync(destinationDir, { recursive: true });
  for (const entry of readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = join(sourceDir, entry.name);
    const destinationPath = join(destinationDir, entry.name);
    if (entry.isDirectory()) {
      copyDirectoryStrict(sourcePath, destinationPath, files);
    } else if (entry.isFile()) {
      writeFileSync(destinationPath, readFileSync(sourcePath), { mode: 0o600 });
      chmodSync(destinationPath, 0o600);
      files.push(sourcePath);
    } else {
      throw new Error(`备份包含不支持的链接或文件类型: ${sourcePath}`);
    }
  }
  return files;
}

export function replaceDirectoryFromBackup(sourceDir, backupDir, label = 'restore', options = {}) {
  if (!existsSync(backupDir)) throw new Error(`备份目录不存在: ${backupDir}`);
  mkdirSync(dirname(sourceDir), { recursive: true });
  const token = `${Date.now()}-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  const stagingDir = `${sourceDir}.${label}-staging-${token}`;
  const displacedDir = `${sourceDir}.${label}-replaced-${token}`;
  const files = [];

  try {
    copyDirectoryStrict(backupDir, stagingDir, files);
    if (options.requireFiles && files.length === 0) throw new Error('备份目录为空');
  } catch (err) {
    rmSync(stagingDir, { recursive: true, force: true });
    throw err;
  }

  let originalMoved = false;
  try {
    if (existsSync(sourceDir)) {
      renameSync(sourceDir, displacedDir);
      originalMoved = true;
    }
    renameSync(stagingDir, sourceDir);
  } catch (err) {
    rmSync(stagingDir, { recursive: true, force: true });
    if (originalMoved && !existsSync(sourceDir) && existsSync(displacedDir)) {
      try { renameSync(displacedDir, sourceDir); } catch {}
    }
    throw err;
  }

  let cleanupWarning = '';
  if (originalMoved) {
    try {
      rmSync(displacedDir, { recursive: true, force: true });
    } catch (err) {
      cleanupWarning = `旧目录清理失败，保留于 ${displacedDir}: ${err.message}`;
    }
  }
  return { restoredCount: files.length, cleanupWarning };
}
