import json
import os
import tempfile
import time
from pathlib import PurePosixPath
from urllib.parse import unquote, urlparse

import boto3
import requests
from botocore.config import Config
from botocore.exceptions import ClientError, EndpointConnectionError


def main() -> None:
    bucket = os.environ["SAMPLE_UPLOAD_BUCKET"]
    region = os.environ["SAMPLE_UPLOAD_REGION"]
    urls = json.loads(os.environ["SAMPLE_UPLOAD_URLS"])
    if not isinstance(urls, list) or any(not isinstance(url, str) for url in urls):
        raise ValueError("SAMPLE_UPLOAD_URLS must be a JSON array of URL strings")
    for url in urls:
        if urlparse(url).scheme not in {"http", "https"}:
            raise ValueError(f"Sample document URL must use HTTP or HTTPS: {url}")

    s3 = boto3.client(
        "s3",
        endpoint_url=os.environ["AWS_S3_ENDPOINT"],
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=region,
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1}),
    )

    for attempt in range(60):
        try:
            s3.list_buckets()
            break
        except EndpointConnectionError:
            if attempt == 59:
                raise
            print("S3 storage is not ready; retrying in 5 seconds", flush=True)
            time.sleep(5)
        except ClientError as error:
            status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode", 0)
            if status < 500 or attempt == 59:
                raise
            print(f"S3 storage returned HTTP {status}; retrying in 5 seconds", flush=True)
            time.sleep(5)

    existing_buckets = {item["Name"] for item in s3.list_buckets().get("Buckets", [])}
    if bucket not in existing_buckets:
        try:
            s3.create_bucket(Bucket=bucket)
            print(f"Created bucket {bucket}")
        except ClientError as error:
            code = error.response.get("Error", {}).get("Code")
            if code not in {"BucketAlreadyExists", "BucketAlreadyOwnedByYou"}:
                raise

    for url in urls:
        object_name = PurePosixPath(unquote(urlparse(url).path)).name
        if not object_name:
            raise ValueError(f"URL has no filename: {url}")
        with requests.get(url, stream=True, timeout=(15, 120)) as response:
            response.raise_for_status()
            with tempfile.NamedTemporaryFile() as document:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        document.write(chunk)
                document.flush()
                extra_args = {}
                if content_type := response.headers.get("Content-Type"):
                    extra_args["ContentType"] = content_type
                s3.upload_file(document.name, bucket, object_name, ExtraArgs=extra_args)
        print(f"Uploaded {object_name} to s3://{bucket}/{object_name}")


if __name__ == "__main__":
    main()
