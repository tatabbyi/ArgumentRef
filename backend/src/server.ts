import { loadConfig } from './config.js';
import { createAudioIngestionServer } from './audio/audioIngestionServer.js';

const config = loadConfig();
const server = createAudioIngestionServer(config);

const port = await server.listen();

console.log(`Argument Referee backend listening on ws://${config.host}:${port}/v1/audio`);
console.log(`Health check available at http://${config.host}:${port}/health`);

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    void server.close().finally(() => {
      process.exit(0);
    });
  });
}
