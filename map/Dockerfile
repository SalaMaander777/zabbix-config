FROM --platform=linux/amd64 python:3.12-alpine
RUN pip install --no-cache-dir openpyxl==3.1.5
WORKDIR /srv
COPY app /srv/app
COPY static /srv/static
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8081/healthz >/dev/null || exit 1
USER 65534
CMD ["python3", "-m", "app.server"]
