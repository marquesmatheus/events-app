FROM python:3.12-slim

RUN apt-get update && apt-get install -y curl unzip awscli && \
    curl -fsSL https://releases.hashicorp.com/terraform/1.9.0/terraform_1.9.0_linux_amd64.zip -o /tmp/tf.zip && \
    unzip /tmp/tf.zip -d /usr/local/bin && rm /tmp/tf.zip && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/api.py backend/worker.py backend/start.sh .
COPY terraform/ terraform/

EXPOSE 8000

RUN chmod +x start.sh
CMD ["./start.sh"]
