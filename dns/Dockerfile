# python:3.12-slim — no apt-get on purpose (broken host HTTP proxy).
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 80 443 53/udp 53/tcp

CMD ["bash"]
