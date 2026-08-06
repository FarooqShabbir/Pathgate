import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// base: './' makes every built asset reference relative, so the same
// build works whether it's served at / (local `vite preview`) or at
// /app1/ behind the nginx / ALB / CloudFront reverse proxy.
export default defineConfig({
  plugins: [react()],
  base: './',
})
