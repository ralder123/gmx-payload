#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="${1:-./payload3}"

if [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: Directory not found: $PROJECT_DIR" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
BACKUP_DIR="$PROJECT_DIR/.build-fix-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

echo "Checking project: $PROJECT_DIR"
echo "Backup directory: $BACKUP_DIR"
echo

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

backup_file() {
  local file="$1"

  if [ -f "$PROJECT_DIR/$file" ]; then
    cp -p "$PROJECT_DIR/$file" "$BACKUP_DIR/$(basename "$file")"
    echo "Backed up: $file"
  fi
}

# ----------------------------------------
# Check required files
# ----------------------------------------

[ -f "$PROJECT_DIR/package.json" ] || fail "package.json is missing."
[ -f "$PROJECT_DIR/pnpm-lock.yaml" ] || fail "pnpm-lock.yaml is missing."
[ -f "$PROJECT_DIR/next.config.ts" ] || fail "next.config.ts is missing."

echo "Required files found."
echo

# ----------------------------------------
# Back up files before changing them
# ----------------------------------------

backup_file "next.config.ts"
backup_file "Dockerfile"
backup_file ".dockerignore"

# ----------------------------------------
# Check package manager files
# ----------------------------------------

if [ -f "$PROJECT_DIR/package-lock.json" ]; then
  echo "WARNING: package-lock.json exists. Removing it because this project uses pnpm."
  rm "$PROJECT_DIR/package-lock.json"
fi

if [ -f "$PROJECT_DIR/yarn.lock" ]; then
  echo "WARNING: yarn.lock exists. Removing it because this project uses pnpm."
  rm "$PROJECT_DIR/yarn.lock"
fi

# ----------------------------------------
# Fix next.config.ts
# ----------------------------------------

echo
echo "Checking next.config.ts..."

python3 - "$PROJECT_DIR/next.config.ts" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

# Remove duplicate plain Next.js export.
lines = []
removed_duplicate = False

for line in text.splitlines():
    if line.strip() == "export default nextConfig":
        removed_duplicate = True
        continue
    lines.append(line)

text = "\n".join(lines).rstrip() + "\n"

# Ensure standalone output is configured.
if "output: 'standalone'" not in text and 'output: "standalone"' not in text:
    marker = "const nextConfig: NextConfig = {\n"

    if marker not in text:
        raise SystemExit(
            "Could not find 'const nextConfig: NextConfig = {'"
        )

    text = text.replace(
        marker,
        marker + "  output: 'standalone',\n",
        1,
    )

# Ensure Payload's wrapper is the only default export.
payload_export = "export default withPayload(nextConfig)"

if payload_export not in text:
    text = text.rstrip() + "\n\n" + payload_export + "\n"

path.write_text(text)

print("Fixed next.config.ts")
if removed_duplicate:
    print("Removed duplicate: export default nextConfig")
PY

# ----------------------------------------
# Generate build Dockerfile
# ----------------------------------------

echo
echo "Generating Dockerfile..."

cat > "$PROJECT_DIR/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1

FROM node:22-alpine AS deps

WORKDIR /app

RUN apk add --no-cache libc6-compat
RUN corepack enable

COPY package.json pnpm-lock.yaml ./

RUN pnpm install \
    --frozen-lockfile \
    --dangerously-allow-all-builds


FROM node:22-alpine AS builder

WORKDIR /app

RUN apk add --no-cache libc6-compat
RUN corepack enable

COPY --from=deps /app/node_modules ./node_modules
COPY . .

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# The application must check this in generateStaticParams().
ENV SKIP_DB_DURING_BUILD=true

RUN pnpm run build


FROM node:22-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 nextjs \
    && mkdir -p /app/public \
    && chown -R nextjs:nodejs /app

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000

CMD ["node", "server.js"]
EOF

echo "Generated Dockerfile."

# ----------------------------------------
# Generate .dockerignore
# ----------------------------------------

echo
echo "Generating .dockerignore..."

cat > "$PROJECT_DIR/.dockerignore" <<'EOF'
node_modules
.next
.git
.gitignore

.env
.env.*
!.env.example

Dockerfile
docker-compose.yml
docker-compose.yaml
docker-compose*.yml
docker-compose*.yaml

npm-debug.log*
yarn-debug.log*
pnpm-debug.log*
EOF

echo "Generated .dockerignore."

# ----------------------------------------
# Find database access and static params
# ----------------------------------------

echo
echo "Checking source files for database/static-generation code..."

SEARCH_DIR="$PROJECT_DIR/src"

if [ -d "$SEARCH_DIR" ]; then
  grep -RIn \
    --exclude-dir=node_modules \
    --exclude-dir=.next \
    -E "generateStaticParams|getPayload|payload\.init|DATABASE_URI|DATABASE_URL" \
    "$SEARCH_DIR" 2>/dev/null || true
else
  echo "WARNING: src directory was not found."
fi

echo
echo "Checking generateStaticParams() files..."

MATCHES="$(
  grep -RIl \
    --exclude-dir=node_modules \
    --exclude-dir=.next \
    "generateStaticParams" \
    "$SEARCH_DIR" 2>/dev/null || true
)"

if [ -n "$MATCHES" ]; then
  echo
  echo "These files may need a build guard:"
  printf '%s\n' "$MATCHES"
  echo
  echo "Add this inside each database-backed generateStaticParams():"
  echo
  cat <<'EOF'
if (process.env.SKIP_DB_DURING_BUILD === 'true') {
  return []
}
EOF
else
  echo "No generateStaticParams() found."
fi

# ----------------------------------------
# Check default exports
# ----------------------------------------

echo
echo "Validating next.config.ts..."

EXPORT_COUNT="$(
  grep -Ec '^[[:space:]]*export default ' "$PROJECT_DIR/next.config.ts" || true
)"

if [ "$EXPORT_COUNT" -eq 1 ]; then
  echo "OK: exactly one default export found."
else
  echo "WARNING: found $EXPORT_COUNT default exports."
fi

# ----------------------------------------
# Check package scripts
# ----------------------------------------

echo
echo "Checking package.json build script..."

python3 - "$PROJECT_DIR/package.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
package = json.loads(path.read_text())
scripts = package.get("scripts", {})

if "build" not in scripts:
    print("WARNING: package.json does not contain a build script.")
else:
    print(f"Build command: {scripts['build']}")
PY

echo
echo "Build-file fix completed."
echo
echo "Modified files:"
echo "  $PROJECT_DIR/next.config.ts"
echo "  $PROJECT_DIR/Dockerfile"
echo "  $PROJECT_DIR/.dockerignore"
echo
echo "Backup:"
echo "  $BACKUP_DIR"
echo
echo "Next step after adding any generateStaticParams() guards:"
echo "  cd \"$PROJECT_DIR\""
echo "  docker build --no-cache -t payload3 ."

