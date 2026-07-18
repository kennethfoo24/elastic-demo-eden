FROM node:20-alpine

# better-sqlite3 compiles a native addon at install time.
RUN apk add --no-cache python3 make g++

RUN mkdir -p /home/node/app/node_modules
WORKDIR /home/node/app

COPY . .

RUN --mount=type=cache,target=/root/.npm npm install
RUN --mount=type=cache,target=/root/.npm npm run build

ENV NO_TLS=1
# SQLite DB lives here — mount a PVC at this path so seeded tickets and any
# incidents pushed in by the outbound .servicenow action connector survive
# pod restarts (see helm3/templates/snowem.yaml).
ENV SNOWEM_DB_PATH=/data/snowem.db
VOLUME /data

CMD [ "npm", "start"]
