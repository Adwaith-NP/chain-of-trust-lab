FROM python:3.12-slim

# Apache (the web server of SEED Task 4) and curl (certificate enrollment).
# apt is switched to HTTPS: this Mac sends container HTTP through a dead
# proxy, but HTTPS goes out directly.
RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends apache2 curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 80 443 4433

CMD ["bash", "apache/start.sh"]
