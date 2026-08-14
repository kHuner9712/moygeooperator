# geo-operator deterministic mock services (True n8n E2E gate only).
# Exposes SearXNG/Crawl4AI-compatible endpoints plus a fail-injection endpoint.
FROM python:3.12-alpine
WORKDIR /srv/mock
COPY mock-server.py .
EXPOSE 8080 8000 8010
CMD ["python", "mock-server.py"]
