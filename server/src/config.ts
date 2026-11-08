export const config = {
  port: Number(process.env.PORT ?? 3000),
  databaseUrl: process.env.DATABASE_URL ?? 'postgres://queue:queue@localhost:5432/queue',
  timezone: process.env.QUEUE_TZ ?? 'Africa/Ouagadougou',
};
