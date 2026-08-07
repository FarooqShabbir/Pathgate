import { useEffect, useState } from 'react'

// Build-time switch — see the matching comment in
// frontend-insert/src/App.jsx for the full explanation. Short version:
// relative ('api', default) for v1, v2 ECS Fargate, and v2 Elastic
// Beanstalk, where nginx strips /app2/ before this container ever
// sees the request; absolute ('/api', via VITE_API_BASE) only for v2
// Lambda, whose CloudFront routes by the original, unstripped path.
const API_BASE = import.meta.env.VITE_API_BASE || 'api'

export default function App() {
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)

  async function load() {
    setLoading(true)
    setError(false)
    try {
      const res = await fetch(`${API_BASE}/items`)
      if (!res.ok) throw new Error(`Request failed: ${res.status}`)
      setItems(await res.json())
    } catch (err) {
      console.error(err)
      setError(true)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    load()
  }, [])

  return (
    <div className="page">
      <span className="badge">APP 2 · read-only</span>
      <h1>Records</h1>
      <p className="hint">
        This frontend can only call <code>GET /api/items</code>. It has no
        form and no code path that writes data — that lives in App 1.
      </p>
      <button onClick={load} disabled={loading}>
        {loading ? 'Loading…' : 'Refresh'}
      </button>

      {error && <p className="err">Could not reach the backend.</p>}

      {!error && (
        <table>
          <thead>
            <tr>
              <th>Title</th>
              <th>Description</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            {items.length === 0 && !loading && (
              <tr>
                <td colSpan={3} className="empty">No records yet — insert one from App 1.</td>
              </tr>
            )}
            {items.map((it) => (
              <tr key={it.id}>
                <td>{it.title}</td>
                <td>{it.description}</td>
                <td>{new Date(it.created_at).toLocaleString()}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  )
}
