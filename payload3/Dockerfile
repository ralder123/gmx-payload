# syntax=docker/dockerfile:1

# -----------------------------
# Dependencies
# -----------------------------
FROM node:22-alpine AS deps

WORKDIR /app

RUN apk add --no-cache libc6-compat
RUN corepack enable

COPY package.json pnpm-lock.yaml ./

RUN test -f package.json
RUN test -f pnpm-lock.yaml

RUN pnpm install \
    --frozen-lockfile \
    --dangerously-allow-all-builds


# -----------------------------
# Build
# -----------------------------
FROM node:22-alpine AS builder

WORKDIR /app

RUN apk add --no-cache libc6-compat
RUN corepack enable

COPY --from=deps /app/node_modules ./node_modules
COPY . .

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Prevent Payload/PostgreSQL access during next build.
# generateStaticParams() must check this variable.
ENV SKIP_DB_DURING_BUILD=true

# -----------------------------
# Build checks
# -----------------------------
RUN set -eux; \
    test -f package.json; \
    test -f pnpm-lock.yaml; \
    test -f next.config.ts; \
    node -e " \
      const p = require('./package.json'); \
      if (!p.scripts || !p.scripts.build) { \
        console.error('Missing package.json build script'); \
        process.exit(1); \
      } \
      console.log('Build script:', p.scripts.build); \
    "; \
    grep -Eq "output:[[:space:]]*['\"]standalone['\"]" next.config.ts \
      || { \
        echo "ERROR: next.config.ts must contain output: 'standalone'"; \
        exit 1; \
      }; \
    DEFAULT_EXPORTS=$$(grep -Ec '^[[:space:]]*export default ' next.config.ts || true); \
    test "$$DEFAULT_EXPORTS" -eq 1 \
      || { \
        echo "ERROR: next.config.ts must contain exactly one default export"; \
        exit 1; \
      }; \
    grep -RIl \
      --exclude-dir=node_modules \
      --exclude-dir=.next \
      "generateStaticParams" \
      src 2>/dev/null || true

# -----------------------------
# Production build
# -----------------------------
RUN pnpm run build

# Confirm Next.js generated standalone output.
RUN test -f .next/standalone/server.js \
    || { \
      echo "ERROR: .next/standalone/server.js was not generated"; \
      echo "Check that next.config.ts contains output: 'standalone'"; \
      exit 1; \
    }


# -----------------------------
# Runtime
# -----------------------------
FROM node:22-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
ENV SKIP_DB_DURING_BUILD=false

RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 nextjs

# Ensure the directory exists even if the project has no public assets.
RUN mkdir -p /app/public \
    && chown -R nextjs:nodejs /app

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs \
    /app/.next/standalone ./

COPY --from=builder --chown=nextjs:nodejs \
    /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000

CMD ["node", "server.js"]

