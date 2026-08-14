# geo-operator truth-extractor — rely on the official Python slim image to keep
# the image small and self-contained. No system apt packages needed for pypdf /
# bs4 / requests.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=9000

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 9000

# Unprivileged runtime (no root inside the container).
USER 10001:10001

HEALTHCHECK CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:9000/healthz')" || exit 1

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9000"]