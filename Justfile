# Zink - Z-machine v3 interpreter

# Run specs
test:
    crystal spec

# Build the project
build:
    crystal build src/zink.cr -o bin/zink

# Generate API docs
docs:
    crystal docs -o docs/api

# Clean build artifacts
clean:
    rm -rf bin docs/api
