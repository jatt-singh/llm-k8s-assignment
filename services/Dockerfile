# One Dockerfile builds any of the three services: --build-arg SERVICE=gateway|catalog|assistant
# Base images are pinned by digest; bump them deliberately, never implicitly.
# golang 1.27.2 (2026-10-10) is a security release fixing 3 HIGH stdlib CVEs found by trivy in 1.27.1.

FROM golang:1.27.2-alpine@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS build
ARG SERVICE
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Static binary, no cgo, stripped, reproducible paths.
RUN test -n "$SERVICE" && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/${SERVICE}

# Distroless static: no shell, no package manager, runs as uid 65532 (nonroot).
FROM gcr.io/distroless/static-debian13:nonroot@sha256:516757106de35205efb70b91ba03f6f1298424a0678c603255cf2852a7000087
ARG SERVICE
LABEL org.opencontainers.image.title="llmstack-${SERVICE}" \
      org.opencontainers.image.source="local" \
      org.opencontainers.image.licenses="MIT"
COPY --from=build /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
