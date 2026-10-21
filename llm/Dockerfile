# LLM inference workload: upstream llama.cpp server (MIT), pinned by digest.
# Build b11223 (released 2026-09-28). The model is NOT in the image: it is
# downloaded once into a PersistentVolume and mounted read-only at /models.
FROM ghcr.io/ggml-org/llama.cpp:server-b11223@sha256:8fdfad183be053cdb72d4b6a5930c3a2475730f932855ee9260193422c2564ed

LABEL org.opencontainers.image.title="llmstack-llm" \
      org.opencontainers.image.description="llama.cpp server, CPU only, non-root" \
      org.opencontainers.image.licenses="MIT"

# Upstream runs as root. Run as an unprivileged, numeric uid so Kubernetes
# can verify runAsNonRoot.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app/llama-server"]
