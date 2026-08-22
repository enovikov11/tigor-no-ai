FROM docker.io/python:3.13-slim

# Data diode — one-way artifact relay (stdlib only, no pip installs)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git podman && rm -rf /var/lib/apt/lists/*

COPY server.py /usr/local/bin/diode
RUN chmod +x /usr/local/bin/diode

EXPOSE 8080
ENV PORT=8080
CMD ["diode"]
