import { chmodSync, existsSync, renameSync, rmSync, writeFileSync } from 'fs';

export const PRIVATE_FILE_MODE = 0o600;

export function hardenPrivateFile(filePath) {
  if (!existsSync(filePath)) return false;
  chmodSync(filePath, PRIVATE_FILE_MODE);
  return true;
}

export function writePrivateFile(filePath, content, encoding = 'utf-8') {
  const temporaryPath = `${filePath}.tmp-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  try {
    writeFileSync(temporaryPath, content, { encoding, mode: PRIVATE_FILE_MODE });
    chmodSync(temporaryPath, PRIVATE_FILE_MODE);
    renameSync(temporaryPath, filePath);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
  chmodSync(filePath, PRIVATE_FILE_MODE);
}
