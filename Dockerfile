# ========================================
# Builder Stage
# ========================================
FROM ziglings/ziglang:latest AS builder

# Create an unprivileged user early to ensure we can copy the /etc/passwd and /etc/group files 
# to our scratch container later. This provides user context for the non-root execution.
RUN addgroup -g 10001 appgroup && \
    adduser -u 10001 -G appgroup -s /sbin/nologin -D appuser

WORKDIR /app

# Ordering this before the full COPY src/ maximizes layer caching for the source code.
COPY build.zig build.zig.zon ./

# We build with ReleaseFast to prioritize runtime speed.
# Target x86_64-linux-musl to create a fully statically linked binary for the 'scratch' image. 
# Optimize for x86_64_v3 to leverage modern CPU features like AVX2.
# BuildKit cache mounts are used to accelerate subsequent builds.
COPY src/ ./src/
RUN --mount=type=cache,target=/root/.cache/zig \
    --mount=type=cache,target=/app/.zig-cache \
    zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3 --summary all

# ========================================
# Final Production Stage
# ========================================
# We use 'scratch' as the base image for zero overhead and minimal attack surface.
FROM scratch

LABEL maintainer="Klever Correa da Silveira <klevercorrea@icloud.com>"
LABEL org.opencontainers.image.title="Rinha de Backend 2026"
LABEL org.opencontainers.image.description="High-performance Zig backend for the Rinha"
LABEL org.opencontainers.image.authors="Klever Correa da Silveira <klevercorrea@icloud.com>"
LABEL org.opencontainers.image.source="https://github.com/klevercorrea/rinha-de-backend-2026"

WORKDIR /app

# This allows the container runtime to resolve the UID 10001 to 'appuser' (kept for metadata).
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

COPY --from=builder /app/zig-out/bin/rinha /app/rinha

EXPOSE 9999

# Execute the application directly without a shell wrapper to maintain 
# PID 1 and ensure correct signal handling.
ENTRYPOINT ["/app/rinha"]
