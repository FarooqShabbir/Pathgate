import { useState } from 'react'

// Build-time switch, because "how do I reach /api" is not the same
// answer in every deployment:
//   - v1, v2 ECS Fargate (ecs-cli), v2 Elastic Beanstalk: nginx
//     STRIPS /app1/ before forwarding, so this container only ever
//     sees /api/... -> a RELATIVE path ('api', the default below) is
//     required, so the browser request stays /app1/api/... and lands
//     on this container, not the gateway.
//   - v2 Lambda: CloudFront does NOT strip the matched prefix, and
//     routes by the ORIGINAL path -> an ABSOLUTE path ('/api') is
//     required instead, so the request is literally /api/... and
//     matches CloudFront's own /api/* behavior directly, bypassing
//     this frontend entirely (there's no compute in S3 to proxy
//     through anyway). deploy_frontends.sh sets VITE_API_BASE=/api
//     at build time for that one case.
// Get this backwards and requests 404 or silently return the app's
// own index.html instead of JSON — there is no runtime fallback.
const API_BASE = import.meta.env.VITE_API_BASE || 'api'

export default function App() {
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [status, setStatus] = useState(null)

  async function handleSubmit(e) {
    e.preventDefault()
    setStatus('sending')
    try {
      const res = await fetch(`${API_BASE}/items`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ title, description }),
      })
      if (!res.ok) throw new Error(`Request failed: ${res.status}`)
      setTitle('')
      setDescription('')
      setStatus('success')
    } catch (err) {
      console.error(err)
      setStatus('error')
    }
  }

  return (
    <div className="page">
      <span className="badge">APP 1 · write-only</span>
      <h1>Insert a record</h1>
      <p className="hint">
        This frontend can only call <code>POST /api/items</code>. It has no
        code path that reads data back — that lives in App 2.
      </p>
      <form onSubmit={handleSubmit}>
        <label>
          Title
          <input value={title} onChange={(e) => setTitle(e.target.value)} required />
        </label>
        <label>
          Description
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={4}
          />
        </label>
        <button type="submit" disabled={status === 'sending'}>
          {status === 'sending' ? 'Saving…' : 'Insert'}
        </button>
      </form>
      {status === 'success' && <p className="ok">Saved to the database.</p>}
      {status === 'error' && <p className="err">Insert failed — check the backend logs.</p>}
    </div>
  )
}
