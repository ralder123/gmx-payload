import { withPayload } from '@payloadcms/next/withPayload'
import type { NextConfig } from 'next'
import path from 'path'
import { fileURLToPath } from 'url'

import { redirects } from './redirects'

const __filename = fileURLToPath(import.meta.url)
const dirname = path.dirname(__filename)

const NEXT_PUBLIC_SERVER_URL =
  process.env.NEXT_PUBLIC_SERVER_URL || 'http://localhost:3000'

const nextConfig: NextConfig = {
  output: 'standalone',

  sassOptions: {
    loadPaths: ['./node_modules/@payloadcms/ui/dist/scss/'],
  },

  images: {
    localPatterns: [
      {
        pathname: '/api/media/file/**',
      },
    ],

    qualities: [90, 100],

    remotePatterns: [NEXT_PUBLIC_SERVER_URL].map((item) => {
      const url = new URL(item)

      return {
        hostname: url.hostname,
        protocol: url.protocol.replace(':', '') as 'http' | 'https',
      }
    }),
  },

  reactStrictMode: true,

  redirects,

  webpack: (webpackConfig) => {
    webpackConfig.resolve.extensionAlias = {
      '.cjs': ['.cts', '.cjs'],
      '.js': ['.ts', '.tsx', '.js', '.jsx'],
      '.mjs': ['.mts', '.mjs'],
    }

    return webpackConfig
  },

  turbopack: {
    root: path.resolve(dirname),
  },
}

export default withPayload(nextConfig)
