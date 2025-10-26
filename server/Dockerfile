# Multi-stage build for Dart server on Render
FROM dart:stable AS build
WORKDIR /app

# Copy pubspec and resolve dependencies
COPY server/pubspec.* ./
RUN dart pub get

# Copy source and compile to native executable for faster startup
COPY server/ ./
RUN dart pub get --offline && dart compile exe bin/server.dart -o bin/server

# Runtime image
FROM gcr.io/distroless/dart:stable AS runtime
WORKDIR /app
COPY --from=build /runtime/ /runtime/
COPY --from=build /app/bin/server /app/server

# Render provides PORT env var
ENV PORT=8080
EXPOSE 8080

# Run the compiled binary
CMD ["/app/server"]
