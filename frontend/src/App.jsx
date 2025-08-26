import React, { useState } from 'react'
import CONFIG from './config.js'

export default function App() {
  const [file, setFile] = useState(null)
  const [status, setStatus] = useState('')
  const [imageId, setImageId] = useState('')
  const [links, setLinks] = useState([])

  async function initUpload(preferredSizes) {
    setStatus('Requesting presigned POST...')

    const res = await fetch(`${CONFIG.API_BASE}/images/init-upload`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(preferredSizes?.length ? { sizes: preferredSizes } : {})
    })
    
    if (!res.ok) throw new Error(`Init failed: ${res.status}`)
    
    return res.json()
  }

  async function uploadToS3(presigned, file) {
    setStatus('Uploading to S3...')

    const formData = new FormData()
    Object.entries(presigned.fields).forEach(([k, v]) => formData.append(k, v))
    formData.append('file', file)
    const uploadRes = await fetch(presigned.url, { method: 'POST', body: formData })

    if (!uploadRes.ok) {
      const text = await uploadRes.text()
      throw new Error(`S3 upload failed: ${uploadRes.status} ${text}`)
    }
  }

  async function handleSubmit(e) {
    e.preventDefault()
    setLinks([])

    try {
      if (!file) throw new Error('Select a file first')

      const preferredSizes = (e.target.elements.sizes.value || 'thumb,medium,large')
        .split(',').map(s => s.trim()).filter(Boolean)
      const { imageId, upload, sizes } = await initUpload(preferredSizes)

      setImageId(imageId)

      await uploadToS3(upload, file)

      setStatus('Uploaded! Variants will appear after processing.')

      const cf = CONFIG.CLOUDFRONT_DOMAIN.replace(/^https?:\/\//, '')
      const urls = sizes.map(s => `https://${cf}/images/${imageId}/${s}.jpg`)

      setLinks(urls)
    } catch (err) {
      console.error(err)
      setStatus(err.message || 'Something went wrong')
    }
  }

  return (
    <div style={{maxWidth: 680, margin: '2rem auto', fontFamily: 'system-ui, sans-serif'}}>
      <h1>Image Pipeline Demo</h1>
      <form onSubmit={handleSubmit}>
        <div style={{marginBottom: '1rem'}}>
          <label>Choose an image: </label>
          <input type="file" accept="image/*" onChange={e => setFile(e.target.files[0] || null)} />
        </div>
        <div style={{marginBottom: '1rem'}}>
          <label>Sizes (comma-separated): </label>
          <input name="sizes" placeholder="thumb,medium,large" defaultValue="thumb,medium,large" style={{width:'60%'}} />
        </div>
        <button type="submit">Upload</button>
      </form>

      <p style={{marginTop: '1rem'}}><b>Status:</b> {status}</p>
      {imageId && <p><b>imageId:</b> {imageId}</p>}
      {!!links.length && (
        <div>
          <h3>CloudFront Links (may 404 until processed):</h3>
          <ul>
            {links.map(u => <li key={u}><a href={u} target="_blank">{u}</a></li>)}
          </ul>
        </div>
      )}
    </div>
  )
}
