FROM dart:stable
WORKDIR /app

# With render.yaml rootDir=server, the build context is server/
# Copy pubspec first to leverage Docker layer caching
COPY pubspec.* ./
RUN dart pub get

# Copy the rest of the server sources
COPY . ./

# Render provides PORT env var
ENV PORT=8080
EXPOSE 8080

# Run the server
CMD ["dart", "run", "bin/server.dart"]
