import hashlib
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import time
import uuid
import zipfile
from io import BytesIO
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


# Запас до лимита ответа API Gateway 2.5 МБ, включая ZIP-заголовки.
MAX_SOURCE_BYTES = 2_000_000
CHUNK_SIZE = 64 * 1024
DOWNLOAD_TIMEOUT = 60
TLS = ssl.create_default_context()


class ArchiveError(RuntimeError):
    """Ошибка с безопасным для журнала сообщением."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


CLOUD_HTTP = build_opener(ProxyHandler({}), NoRedirect())


def archive_key(queue_id, message_id, sent_timestamp):
    """Формат RFC 9562: 48 бит времени, версия 7, вариант RFC и 74 бита."""
    timestamp = int(sent_timestamp)
    if not 0 <= timestamp < (1 << 48):
        raise ArchiveError("invalid YMQ timestamp")
    # Детерминированные псевдослучайные биты от уникального ID сообщения.
    # Повторная доставка получает прежний ключ, новый POST получает новый ключ.
    digest = hashlib.sha256(f"{queue_id}\n{message_id}".encode()).digest()
    bits = int.from_bytes(digest[:10], "big")
    rand_a = (bits >> 62) & 0xFFF
    rand_b = bits & ((1 << 62) - 1)
    value = (timestamp << 80) | (7 << 76) | (rand_a << 64) | (2 << 62) | rand_b
    return f"{uuid.UUID(int=value)}.zip"


def source_parts(url):
    if not isinstance(url, str) or not 1 <= len(url) <= 4096 or re.search(r"\s|[\x00-\x1f\x7f\\]", url):
        raise ArchiveError("invalid source URL")
    parts = urlsplit(url)
    if parts.scheme not in {"http", "https"} or not parts.hostname or parts.username is not None:
        raise ArchiveError("expected a public HTTP(S) URL")
    if parts.port is not None and parts.port != (443 if parts.scheme == "https" else 80):
        raise ArchiveError("expected a default HTTP(S) port")
    return parts


def open_source(parts, deadline):
    host = parts.hostname.encode("idna").decode("ascii")
    port = 443 if parts.scheme == "https" else 80
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    for _, _, _, _, address in addresses:
        ip = ipaddress.ip_address(address[0])
        ip = getattr(ip, "ipv4_mapped", None) or ip
        if not ip.is_global or ip.is_multicast or ip.is_reserved:
            raise ArchiveError("source must resolve to public unicast addresses")

    for family, socktype, protocol, _, address in addresses:
        if time.monotonic() >= deadline:
            raise ArchiveError("source download timed out")
        sock = socket.socket(family, socktype, protocol)
        try:
            sock.settimeout(min(8, max(0.1, deadline - time.monotonic())))
            # Используем ровно тот IP, который проверили, без повторного DNS.
            sock.connect(address)
            if parts.scheme == "https":
                sock = TLS.wrap_socket(sock, server_hostname=host)
        except OSError:
            sock.close()
            continue
        except BaseException:
            sock.close()
            raise

        connection = http.client.HTTPConnection(host, port)
        connection.sock = sock
        return connection
    raise ArchiveError("could not connect to the source")


def make_zip(url, name):
    deadline = time.monotonic() + DOWNLOAD_TIMEOUT
    for _ in range(6):
        parts = source_parts(url)
        connection = open_source(parts, deadline)
        with BytesIO() as output:
            try:
                target = quote(parts.path or "/", safe="/%:@!$&'()*+,;=-._~")
                if parts.query:
                    target += "?" + quote(parts.query, safe="/%?:@!$&'()*+,;=-._~")
                host_header = connection.host
                if ":" in host_header:
                    host_header = f"[{host_header}]"
                connection.request("GET", target, headers={"Host": host_header, "Connection": "close"})
                with connection.getresponse() as response:
                    if response.status in {301, 302, 303, 307, 308} and response.getheader("Location"):
                        url = urljoin(url, response.getheader("Location"))
                        continue
                    if response.status != 200:
                        raise ArchiveError(f"source returned HTTP {response.status}")
                    if response.length is not None and response.length > MAX_SOURCE_BYTES:
                        raise ArchiveError("source exceeds 2 MB")

                    expected_length = response.length
                    size = 0
                    # Читаем ответ порциями и записываем его в ZIP под именем из задания.
                    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
                        with archive.open(name, "w") as entry:
                            while chunk := response.read1(CHUNK_SIZE):
                                if time.monotonic() >= deadline:
                                    raise ArchiveError("source download timed out")
                                size += len(chunk)
                                if size > MAX_SOURCE_BYTES:
                                    raise ArchiveError("source exceeds 2 MB")
                                entry.write(chunk)
                    if expected_length is not None and size != expected_length:
                        raise ArchiveError("source response was truncated")
                return output.getvalue()
            finally:
                connection.close()
    raise ArchiveError("too many source redirects")


def store_zip(token, key, name, url):
    bucket = os.environ["BUCKET_NAME"]
    endpoint = f"https://storage.yandexcloud.net/{bucket}/{key}"
    auth = {"Authorization": f"Bearer {token}"}
    # При повторной доставке используем уже сохранённый ZIP.
    try:
        with CLOUD_HTTP.open(Request(endpoint, headers=auth, method="HEAD"), timeout=10):
            return
    except HTTPError as error:
        with error:
            if error.code != 404:
                raise ArchiveError(f"Object Storage HEAD returned HTTP {error.code}") from None

    payload = make_zip(url, name)
    headers = {
        **auth,
        "Content-Type": "application/zip",
        "Content-Disposition": f'attachment; filename="{key}"',
        "If-None-Match": "*",
    }
    try:
        with CLOUD_HTTP.open(Request(endpoint, data=payload, headers=headers, method="PUT"), timeout=20):
            pass
    except HTTPError as error:
        with error:
            if error.code != 412:
                raise ArchiveError(f"Object Storage PutObject returned HTTP {error.code}") from None


def put_archive(token, record):
    payload = {
        "TableName": "archives",
        "Item": {name: {"S": value} for name, value in record.items()},
    }
    headers = {
        "Authorization": f"Bearer {token}",
        "X-Amz-Target": "DynamoDB_20120810.PutItem",
        "Content-Type": "application/x-amz-json-1.0",
    }
    request = Request(os.environ["DOCAPI_ENDPOINT"], data=json.dumps(payload).encode(), headers=headers)
    # Внутри вызова повторяем запрос к YDB при временных сбоях.
    for attempt in range(3):
        try:
            with CLOUD_HTTP.open(request, timeout=12):
                return
        except HTTPError as error:
            with error:
                body = error.read(4096)
                retryable = error.code >= 500 or error.code == 429 or any(
                    reason in body for reason in (b"ThrottlingException", b"ProvisionedThroughputExceededException")
                )
                if attempt == 2 or not retryable:
                    raise ArchiveError(f"YDB PutItem returned HTTP {error.code}") from None
        except (URLError, TimeoutError, http.client.HTTPException):
            if attempt == 2:
                raise ArchiveError("YDB PutItem connection failed") from None
        time.sleep(2 ** attempt)


def handler(event, context):
    try:
        # Триггер передаёт одно сообщение, в body находится JSON задания.
        (message_event,) = event["messages"]
        details = message_event["details"]
        message = details["message"]
        task = json.loads(message["body"])
        name, url = task["name"], task["url"]
        if (not isinstance(name, str) or not 1 <= len(name) <= 255
                or name in {".", ".."} or re.search(r"[/\\:\x00-\x1f\x7f]", name)):
            raise ArchiveError("invalid ZIP entry name")
        source_parts(url)
        key = archive_key(details["queue_id"], message["message_id"], message["attributes"]["SentTimestamp"])
        token = context.token["access_token"]
        # Сначала сохраняем ZIP, затем записываем его метаданные в YDB.
        store_zip(token, key, name, url)
        put_archive(token, {"name": name, "url": url, "key": key})
    except ArchiveError:
        # Исключение сообщает триггеру, что обработка завершилась ошибкой.
        raise
    except Exception as error:
        # Не записываем данные заданий и токены в журнал.
        raise RuntimeError(f"archiving failed ({type(error).__name__})") from None

    print(f"Archive ready: {key}")
    # После успешного возврата триггер удаляет сообщение из очереди.
    return {"key": key}
