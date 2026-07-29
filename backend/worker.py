import os
import time
import boto3
import psycopg2

sqs = boto3.client("sqs", region_name=os.environ["AWS_REGION"])
queue_url = os.environ["SQS_QUEUE_URL"]


def get_conn():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )


def ensure_table(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS events (
                id SERIAL PRIMARY KEY,
                body JSONB NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
        """)
        conn.commit()


if __name__ == "__main__":
    while True:
        try:
            conn = get_conn()
            ensure_table(conn)
            break
        except Exception as e:
            print(f"waiting for database: {e}")
            time.sleep(5)

    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
            )
            for msg in resp.get("Messages", []):
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO events (body) VALUES (%s::jsonb)",
                        (msg["Body"],),
                    )
                    conn.commit()
                sqs.delete_message(
                    QueueUrl=queue_url,
                    ReceiptHandle=msg["ReceiptHandle"],
                )
        except Exception as e:
            print(f"worker error: {e}")
            time.sleep(5)
