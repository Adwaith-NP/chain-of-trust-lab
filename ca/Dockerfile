# python:3.12-slim already ships the openssl CLI, so no apt-get needed.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 80 443

# We work from an interactive shell inside the container:
# run ./setup_ca.sh once, then python app.py
CMD ["bash"]
