FROM alpine:latest

# Install required packages
RUN apk add --no-cache \
    curl \
    jq \
    bash

# Create directory for scripts
WORKDIR /scripts

# Copy the load generation script
COPY generate-load-llmd.sh /scripts/

# Make script executable
RUN chmod +x /scripts/generate-load-llmd.sh

# Run the script with a default duration
CMD ["/scripts/generate-load-llmd.sh", "60"]
