import { existsSync, readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { hardenPrivateFile } from './private-file.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
export const PUBLISHER_LLM_CONFIG_FILE = join(__dirname, '..', 'data', 'inkos-config.json');

export function readPublisherLlmSecrets(configFile = PUBLISHER_LLM_CONFIG_FILE) {
  if (!existsSync(configFile)) return { apiKey: '', reviewApiKey: '' };
  try {
    hardenPrivateFile(configFile);
    const config = JSON.parse(readFileSync(configFile, 'utf-8'));
    return {
      apiKey: typeof config?.apiKey === 'string' ? config.apiKey : '',
      reviewApiKey: typeof config?.reviewApiKey === 'string' ? config.reviewApiKey : '',
    };
  } catch {
    return { apiKey: '', reviewApiKey: '' };
  }
}
