# Data Diode

One-way artifact relay. Requests downloads from trusted sources and returns
raw bytes — no shell, no evaluation, no return path for the fetched side.

```
GET /git?url=https://github.com/user/repo      → tar.gz
GET /npm?name=express                           → npm tarball
GET /pypi?name=requests                         → PyPI sdist
GET /docker?ref=docker.io/library/alpine:latest → podman-loadable tar
GET /url?source=https://example.com/file.tar    → raw relay
GET /tgproxy?server=1.2.3.4&secret=abc          → MTProto JSON
```

## Run

```bash
podman run -p 8080:8080 --device /dev/fuse \
  -v /var/run/containers/storage:/var/run/containers/storage \
  diode:latest
```

## Use

```bash
# Clone a repo through the diode
curl "http://localhost:8080/git?url=https://github.com/user/repo" > repo.tar.gz

# Get a Docker image
curl "http://localhost:8080/docker?ref=alpine:latest" > image.tar
podman load < image.tar

# Relay a URL
curl "http://localhost:8080/url?source=https://github.com/user/repo/archive/main.tar.gz" > main.tar.gz
```

## Security

- Whitelist-only origins (GitHub, GitLab, npm, PyPI, Docker Hub, GHCR, Quay)
- No outbound connections except the explicitly requested fetch
- 100 MB response cap (configurable via `MAX_BYTES`)
- No shell evaluation, no code execution on fetched content
