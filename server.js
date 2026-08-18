// Continuum — Disaster Recovery Management API
// In-memory REST backend serving incidents, resources, and response teams.
// Swap the in-memory store for a real database (Postgres, Mongo, etc.) when ready —
// every route only touches the `db` object below, so that's the one place to change.

const express = require('express');
const cors = require('cors');

const app = express();
const PORT = process.env.PORT || 4000;

app.use(cors());
app.use(express.json());

// ---------------------------------------------------------------------------
// In-memory data store
// ---------------------------------------------------------------------------

let nextIncidentId = 5;

const db = {
  incidents: [
    {
      id: 1,
      title: 'Regional data center outage — US-East',
      severity: 'critical',
      status: 'responding',
      region: 'US-East',
      affectedUsers: 4230,
      lead: 'Sarah Chen',
      team: 'Infrastructure',
      detectedAt: minutesAgo(22)
    },
    {
      id: 2,
      title: 'Network connectivity degradation — Europe',
      severity: 'high',
      status: 'investigating',
      region: 'Europe',
      affectedUsers: null,
      lead: 'Marcus Rodriguez',
      team: 'Network ops',
      detail: 'API latency +45%',
      detectedAt: minutesAgo(75)
    },
    {
      id: 3,
      title: 'Database replication lag — Asia-Pacific',
      severity: 'high',
      status: 'investigating',
      region: 'Asia-Pacific',
      affectedUsers: null,
      lead: 'Yuki Tanaka',
      team: 'Database admin',
      detail: 'Lag: 12.3s',
      detectedAt: minutesAgo(225)
    },
    {
      id: 4,
      title: 'Elevated error rate — Payments API',
      severity: 'moderate',
      status: 'monitoring',
      region: 'Global',
      affectedUsers: null,
      lead: 'Priya Nair',
      team: 'Platform',
      detail: 'Error rate 2.1%',
      detectedAt: minutesAgo(302)
    }
  ],

  resources: [
    { id: 'compute', label: 'Compute — standby servers', used: 287, total: 420, unit: '' },
    { id: 'bandwidth', label: 'Network bandwidth', used: 342, total: 500, unit: 'Gbps' },
    { id: 'backup', label: 'Backup storage verified', used: 91, total: 100, unit: '%' },
    { id: 'oncall', label: 'On-call responders', used: 12, total: 15, unit: '' }
  ],

  teams: [
    { id: 1, name: 'Sarah Chen', role: 'Infrastructure lead', status: 'responding' },
    { id: 2, name: 'Marcus Rodriguez', role: 'Network operations', status: 'responding' },
    { id: 3, name: 'Yuki Tanaka', role: 'Database admin', status: 'investigating' },
    { id: 4, name: 'Priya Nair', role: 'Platform team', status: 'investigating' },
    { id: 5, name: 'James Kim', role: 'Security response', status: 'standby' },
    { id: 6, name: 'Amara Okafor', role: 'Comms lead', status: 'standby' }
  ]
};

function minutesAgo(mins) {
  return new Date(Date.now() - mins * 60 * 1000).toISOString();
}

const SEVERITIES = ['critical', 'high', 'moderate', 'low'];
const STATUSES = ['monitoring', 'investigating', 'responding', 'resolved'];

// ---------------------------------------------------------------------------
// Health check
// ---------------------------------------------------------------------------

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', time: new Date().toISOString() });
});

// ---------------------------------------------------------------------------
// Incidents
// ---------------------------------------------------------------------------

// GET /api/incidents?severity=critical&status=responding
app.get('/api/incidents', (req, res) => {
  let results = [...db.incidents];
  const { severity, status } = req.query;

  if (severity) results = results.filter(i => i.severity === severity);
  if (status) results = results.filter(i => i.status === status);

  results.sort((a, b) => new Date(a.detectedAt) - new Date(b.detectedAt));

  res.json({
    count: results.length,
    incidents: results
  });
});

// GET /api/incidents/:id
app.get('/api/incidents/:id', (req, res) => {
  const incident = db.incidents.find(i => i.id === Number(req.params.id));
  if (!incident) return res.status(404).json({ error: 'Incident not found.' });
  res.json(incident);
});

// POST /api/incidents — report a new incident
app.post('/api/incidents', (req, res) => {
  const { title, severity, region, lead, team, detail, affectedUsers } = req.body;

  if (!title || typeof title !== 'string' || !title.trim()) {
    return res.status(400).json({ error: 'title is required.' });
  }
  if (!severity || !SEVERITIES.includes(severity)) {
    return res.status(400).json({ error: `severity must be one of: ${SEVERITIES.join(', ')}.` });
  }

  const incident = {
    id: nextIncidentId++,
    title: title.trim(),
    severity,
    status: 'monitoring',
    region: region || 'Unspecified',
    affectedUsers: affectedUsers ?? null,
    lead: lead || 'Unassigned',
    team: team || 'Unassigned',
    detail: detail || null,
    detectedAt: new Date().toISOString()
  };

  db.incidents.unshift(incident);
  res.status(201).json(incident);
});

// PATCH /api/incidents/:id/status — update incident status (e.g. escalate, resolve)
app.patch('/api/incidents/:id/status', (req, res) => {
  const incident = db.incidents.find(i => i.id === Number(req.params.id));
  if (!incident) return res.status(404).json({ error: 'Incident not found.' });

  const { status } = req.body;
  if (!status || !STATUSES.includes(status)) {
    return res.status(400).json({ error: `status must be one of: ${STATUSES.join(', ')}.` });
  }

  incident.status = status;
  res.json(incident);
});

// DELETE /api/incidents/:id — close out an incident record
app.delete('/api/incidents/:id', (req, res) => {
  const index = db.incidents.findIndex(i => i.id === Number(req.params.id));
  if (index === -1) return res.status(404).json({ error: 'Incident not found.' });

  const [removed] = db.incidents.splice(index, 1);
  res.json({ removed });
});

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

app.get('/api/resources', (req, res) => {
  const withPercent = db.resources.map(r => ({
    ...r,
    percentUsed: Math.round((r.used / r.total) * 100)
  }));
  res.json({ resources: withPercent });
});

// PATCH /api/resources/:id — update usage figures as capacity shifts
app.patch('/api/resources/:id', (req, res) => {
  const resource = db.resources.find(r => r.id === req.params.id);
  if (!resource) return res.status(404).json({ error: 'Resource not found.' });

  const { used, total } = req.body;
  if (used !== undefined) {
    if (typeof used !== 'number' || used < 0) {
      return res.status(400).json({ error: 'used must be a non-negative number.' });
    }
    resource.used = used;
  }
  if (total !== undefined) {
    if (typeof total !== 'number' || total <= 0) {
      return res.status(400).json({ error: 'total must be a positive number.' });
    }
    resource.total = total;
  }

  res.json({ ...resource, percentUsed: Math.round((resource.used / resource.total) * 100) });
});

// ---------------------------------------------------------------------------
// Response teams
// ---------------------------------------------------------------------------

app.get('/api/teams', (req, res) => {
  res.json({ teams: db.teams });
});

// PATCH /api/teams/:id/status — update a responder's status
app.patch('/api/teams/:id/status', (req, res) => {
  const member = db.teams.find(t => t.id === Number(req.params.id));
  if (!member) return res.status(404).json({ error: 'Team member not found.' });

  const { status } = req.body;
  const validStatuses = ['responding', 'investigating', 'standby'];
  if (!status || !validStatuses.includes(status)) {
    return res.status(400).json({ error: `status must be one of: ${validStatuses.join(', ')}.` });
  }

  member.status = status;
  res.json(member);
});

// ---------------------------------------------------------------------------
// Dashboard summary — powers the hero metrics on the frontend
// ---------------------------------------------------------------------------

app.get('/api/summary', (req, res) => {
  const critical = db.incidents.filter(i => i.severity === 'critical').length;
  const high = db.incidents.filter(i => i.severity === 'high').length;
  const activeTeams = db.teams.filter(t => t.status !== 'standby').length;

  const totalUsed = db.resources.reduce((sum, r) => sum + r.used, 0);
  const totalCapacity = db.resources.reduce((sum, r) => sum + r.total, 0);
  const recoveredPercent = totalCapacity
    ? Math.round((totalUsed / totalCapacity) * 100)
    : 0;

  res.json({
    critical,
    high,
    activeTeams,
    recoveredPercent
  });
});

// ---------------------------------------------------------------------------
// 404 + error handling
// ---------------------------------------------------------------------------

app.use((req, res) => {
  res.status(404).json({ error: 'Not found.' });
});

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'Internal server error.' });
});

app.listen(PORT, () => {
  console.log(`Continuum DR backend running on http://localhost:${PORT}`);
});
