# Token-free build of apl-tasks with the vikunja_groups claim mapper (apl-tasks.patch).
#
# apl-tasks' own Dockerfile runs `npm ci` against GitHub Packages, which needs an NPM_TOKEN with
# read:packages -- GitHub Packages requires auth even for public packages. The published
# linode/apl-tasks:main image already carries a resolved node_modules including @linode/*, so we
# borrow it instead of resolving again. Only the compiler and its @types come from public npm.
# Same technique as the removed apl-tasks-vikunja.Dockerfile (git history, commit cfa8e5200) --
# this patch is much smaller (two edited files, no new operator), so it gets its own Dockerfile
# rather than reviving that one.

FROM docker.io/linode/apl-tasks:main AS deps

FROM node:22.21.1-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
# jest.config.ts is not optional here. tsconfig's `include` lists it alongside ./src/**/*.ts, and
# tsc infers rootDir from the common ancestor of the files it actually finds. Without it rootDir
# collapses to src/ and the output lands in dist/operators/ instead of dist/src/operators/, with
# tsc still exiting 0 -- the image would then run the OLD unpatched code from the base layer with
# no error anywhere.
COPY package.json tsconfig.json jest.config.ts ./
COPY src ./src
# --no-package-lock stops npm from re-resolving the @linode deps already present.
RUN npm install --no-package-lock --no-audit --no-fund \
      typescript@5.9.3 \
      @types/node@24.10.0 @types/lodash@4.17.20 @types/async-retry@1.4.9 \
      @types/express@5.0.5 @types/js-yaml@4.0.9
RUN npx tsc \
 && cp src/operators/harbor/harbor-full-robot-system-permissions.json dist/src/operators/harbor/
RUN grep -q 'vikunja-groups' dist/src/tasks/keycloak/config.js \
 && grep -q 'vikunja_groups' dist/src/tasks/keycloak/realm-factory.js

FROM docker.io/linode/apl-tasks:main
USER root
COPY --from=build /app/dist /app/dist
COPY package.json /app/package.json
USER node
