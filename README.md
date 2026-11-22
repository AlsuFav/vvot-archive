# Архивирование файлов в Yandex Cloud

API-шлюз проверяет задание и отправляет его в Yandex Message Queue. Триггер передаёт функции по одному сообщению. Функция скачивает файл, сохраняет ZIP с ключом `<uuid_v7>.zip` в закрытом бакете Object Storage и записывает `name`, `url`, `key` в документную таблицу `archives` базы YDB Serverless. Задания с ошибкой переходят в очередь необработанных заданий по политике YMQ с `maxReceiveCount = 1`.

## API

| Запрос | Результат | Интеграция |
| --- | --- | --- |
| `POST /tasks` | `202` для принятого задания, `400` для некорректного JSON | `cloud_ymq` → `SendMessage` |
| `GET /archives` | `200`, массив записей об архивах | `cloud_ydb` → `Scan` |
| `GET /archives/{key}` | `200`, запись об архиве, или `404` | `cloud_ydb` → `GetItem` |
| `GET /download/{key}` | `200`, `application/zip`, или `404` | `object_storage` |

Тело задания — JSON с обязательными строковыми полями `name` и `url`. Функция принимает публичные HTTP(S) URL на стандартных портах. Размер исходного файла ограничен 2 000 000 байт с учётом лимита ответа шлюза. [Лимиты API Gateway](https://yandex.cloud/ru/docs/api-gateway/concepts/limits)

## Файлы проекта

- `openapi.yaml` — спецификация OpenAPI 3.0 с интеграциями шлюза.
- `function/index.py` — обработчик сообщений YMQ на Python 3.14.
- `main.tf` — облачные ресурсы и роли сервисных аккаунтов. В YDB Serverless задано ограничение 10 RU/с и 1 ГБ данных. Документная таблица создаётся через Document API скриптом `scripts/create-table.sh`. [Настройка YDB Serverless](https://yandex.cloud/ru/docs/ydb/terraform/serverless-database) · [Document API YDB](https://yandex.cloud/ru/docs/ydb/docapi/tools/aws-http)
- `scripts/smoke-test.sh` — проверка HTTP-ответов, формата UUIDv7 и содержимого ZIP.

## Развёртывание и проверка

Нужны Terraform 1.5 или новее, настроенный `yc`, `bash`, `curl`, `jq`, `unzip` и доступ к каталогу Yandex Cloud с правами на создание ресурсов и назначение ролей. Terraform получает IAM-токен из `YC_TOKEN`. Значение `TF_VAR_bucket_name` должно быть глобально уникальным и начинаться с `local.prefix` из `main.tf`. [Аутентификация Terraform](https://yandex.cloud/ru/docs/terraform/authentication)

```bash
export TF_VAR_cloud_id="$(yc config get cloud-id)"
export TF_VAR_folder_id="$(yc config get folder-id)"
export TF_VAR_bucket_name='vvot00-archive-your-unique-suffix' # замените на своё имя бакета с нужным префиксом
export YC_TOKEN="$(yc iam create-token)"

terraform init
terraform validate
terraform plan
terraform apply
terraform output -raw api_url
bash scripts/smoke-test.sh
```

`api_url` выводит служебный HTTPS-домен шлюза. Проверка ожидает `400`, `202`, `200` и `404`, проверяет имя файла в ZIP и сравнивает распакованные данные с исходным файлом. Успешный прогон завершается строкой `PASS`.

## Удаление ресурсов

```bash
export YC_TOKEN="$(yc iam create-token)"
terraform destroy
terraform state list
```

`terraform destroy` удаляет ресурсы проекта, включая объекты бакета и документную таблицу вместе с базой. Состояние Terraform содержит служебный ключ YMQ и хранится локально.
