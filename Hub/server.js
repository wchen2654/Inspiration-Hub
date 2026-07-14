// server.js
const express = require('express');
const app = express();
const port = process.env.PORT || 8080;

app.get('/', (req, res) => res.send('Hello from Kubernetes!'));
app.get('/health', (req, res) => res.status(200).send('OK')); // for k8s health checks

app.listen(port, () => console.log(`Listening on ${port}`));