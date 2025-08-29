import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    cors: true, // Vite dev server CORS (not strictly needed with proxy)
    proxy: {
      // Anything starting with /api → forward to SAM local on 3000
      '/api': {
        target: 'https://ktjo7vqhpk.execute-api.us-east-1.amazonaws.com',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, '')
      }
    }
  }
})
