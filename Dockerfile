FROM alpine/azure_cli:latest

# Build arguments
ARG ARTIFACT_VERSION=dev
ARG BUILD_DATE

# Switch to edge repository for latest packages and upgrade all existing packages
RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \
    apk update && \
    apk upgrade --no-cache

# Install required packages
RUN apk add --no-cache \
    jq \
    bash \
    curl \
    python3 \
    py3-pip

# Upgrade Azure CLI to latest version
RUN pip3 install --upgrade --no-cache-dir azure-cli

# Display Azure CLI version
RUN az version

# Verify Python modules are available (smtplib and email are part of Python standard library)
RUN python3 -c "import smtplib; from email.mime.text import MIMEText; from email.mime.multipart import MIMEMultipart; print('Python modules verified')"

# Create app directory
WORKDIR /app

# Copy the sync script
COPY akv-sync.sh /app/akv-sync.sh

# Make script executable
RUN chmod +x /app/akv-sync.sh

# Set version as environment variables
ENV SCRIPT_VERSION=${ARTIFACT_VERSION}
ENV SCRIPT_BUILD_DATE=${BUILD_DATE}

# Set the entrypoint
ENTRYPOINT ["/app/akv-sync.sh"]
