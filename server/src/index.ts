import { buildServer } from './app.js';
import { migrate, pool } from './db.js';
import { config } from './config.js';

await migrate();
const { server } = buildServer();
server.listen(config.port, '0.0.0.0', () => {
  console.log(`OMZA QUEUE server en écoute sur le port ${config.port}`);
});

const stop = () => server.close(() => pool.end().then(() => process.exit(0)));
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
