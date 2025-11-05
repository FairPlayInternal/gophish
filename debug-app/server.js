const express = require('express');

const app = express();
const port = process.env.PORT || 80;
const startedAt = new Date();

app.get('/', (_req, res) => {
  res.json({
    status: 'ok',
    message: 'Gophish debug container is running',
    startedAt: startedAt.toISOString(),
  });
});

app.listen(port, () => {
  console.log(`Debug server listening on port ${port}`);
});
