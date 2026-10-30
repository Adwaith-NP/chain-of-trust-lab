FROM python:3.12-slim

# Apache (TLS front end) and openssl (to mint the self-signed rogue cert).
# Same apt-over-HTTPS workaround as the other instances.
RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends apache2 openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 80 443

CMD ["bash", "apache/start.sh"]
