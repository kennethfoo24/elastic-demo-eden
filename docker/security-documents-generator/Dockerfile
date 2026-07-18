FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

ARG GENERATOR_REF=main
RUN git clone --depth 1 --branch ${GENERATOR_REF} \
    https://github.com/elastic/security-documents-generator.git /app

WORKDIR /app
RUN corepack enable && yarn install

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["generate-alerts", "-n", "25"]
