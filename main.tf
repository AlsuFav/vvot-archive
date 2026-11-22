terraform {
  required_version = ">= 1.5, < 2.0"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "= 0.244.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7.0"
    }
  }
}

provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = "ru-central1-a"
}

locals {
  # Замените 00 на свой двузначный номер перед первым apply.
  prefix = "vvot00-"

  accounts = toset(["queue-admin", "gateway", "trigger", "worker"])
  grants = {
    queue_admin   = { account = "queue-admin", role = "ymq.admin" }
    gateway_queue = { account = "gateway", role = "ymq.writer" }
    gateway_db    = { account = "gateway", role = "ydb.viewer" }
    gateway_files = { account = "gateway", role = "storage.viewer" }
    trigger_queue = { account = "trigger", role = "ymq.reader" }
    trigger_call  = { account = "trigger", role = "functions.functionInvoker" }
    worker_files  = { account = "worker", role = "storage.uploader" }
    worker_db     = { account = "worker", role = "ydb.editor" }
  }
}

variable "cloud_id" {
  type        = string
  description = "ID облака Yandex Cloud."
}

variable "folder_id" {
  type        = string
  description = "ID каталога в этом облаке."
}

variable "bucket_name" {
  type        = string
  description = "Глобально уникальное имя бакета с префиксом студента."
}

resource "yandex_iam_service_account" "service" {
  for_each = local.accounts

  name      = "${local.prefix}${each.key}"
  folder_id = var.folder_id
}

resource "yandex_resourcemanager_folder_iam_member" "grant" {
  for_each = local.grants

  folder_id = var.folder_id
  role      = each.value.role
  member    = "serviceAccount:${yandex_iam_service_account.service[each.value.account].id}"
}

resource "yandex_iam_service_account_static_access_key" "queue" {
  service_account_id = yandex_iam_service_account.service["queue-admin"].id
  description        = "${local.prefix}terraform-ymq"

  depends_on = [yandex_resourcemanager_folder_iam_member.grant["queue_admin"]]
}

resource "yandex_message_queue" "failed" {
  name                      = "${local.prefix}failed"
  message_retention_seconds = 1209600
  access_key                = yandex_iam_service_account_static_access_key.queue.access_key
  secret_key                = yandex_iam_service_account_static_access_key.queue.secret_key
}

resource "yandex_message_queue" "tasks" {
  name                       = "${local.prefix}tasks"
  visibility_timeout_seconds = 900
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 86400
  access_key                 = yandex_iam_service_account_static_access_key.queue.access_key
  secret_key                 = yandex_iam_service_account_static_access_key.queue.secret_key

  # После первого сбоя YMQ перенесёт сообщение в DLQ при чтении по истечении таймаута видимости.
  redrive_policy = jsonencode({
    deadLetterTargetArn = yandex_message_queue.failed.arn
    maxReceiveCount     = 1
  })
}

resource "yandex_ydb_database_serverless" "archives" {
  name                = "${local.prefix}ydb"
  folder_id           = var.folder_id
  deletion_protection = false

  # Для обычной Serverless БД используется OLTP.
  serverless_database {
    enable_throttling_rcu_limit = true
    throttling_rcu_limit        = 10
    storage_size_limit          = 1
  }
}

# Document API создаёт документную таблицу с IAM-токеном из YC_TOKEN.
# Команда запускается в apply после получения endpoint. Таблица удаляется вместе с БД.
resource "terraform_data" "archives_table" {
  triggers_replace = [
    yandex_ydb_database_serverless.archives.id,
    filesha256("${path.module}/scripts/create-table.sh"),
  ]

  provisioner "local-exec" {
    command     = "bash scripts/create-table.sh"
    working_dir = path.module
    environment = {
      DOCAPI_ENDPOINT = yandex_ydb_database_serverless.archives.document_api_endpoint
    }
  }
}

resource "yandex_storage_bucket" "archives" {
  bucket        = var.bucket_name
  folder_id     = var.folder_id
  max_size      = 10737418240 # 10 ГБ в единицах Object Storage.
  force_destroy = true

  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }

  lifecycle {
    precondition {
      condition     = startswith(var.bucket_name, local.prefix)
      error_message = "bucket_name должен начинаться с префикса из local.prefix."
    }
  }
}

data "archive_file" "worker" {
  type        = "zip"
  source_file = "${path.module}/function/index.py"
  output_path = "${path.module}/.archive-function.zip"
}

resource "yandex_function" "worker" {
  name               = "${local.prefix}archiver"
  folder_id          = var.folder_id
  user_hash          = data.archive_file.worker.output_base64sha256
  runtime            = "python314"
  entrypoint         = "index.handler"
  memory             = 256
  execution_timeout  = "600"
  service_account_id = yandex_iam_service_account.service["worker"].id

  content {
    zip_filename = data.archive_file.worker.output_path
  }

  environment = {
    BUCKET_NAME     = yandex_storage_bucket.archives.bucket
    DOCAPI_ENDPOINT = yandex_ydb_database_serverless.archives.document_api_endpoint
  }

  depends_on = [
    terraform_data.archives_table,
    yandex_resourcemanager_folder_iam_member.grant["worker_files"],
    yandex_resourcemanager_folder_iam_member.grant["worker_db"],
  ]
}

resource "yandex_function_trigger" "tasks" {
  name      = "${local.prefix}tasks-trigger"
  folder_id = var.folder_id

  # Триггер вызывает функцию для одного сообщения без ожидания группы.
  message_queue {
    queue_id           = yandex_message_queue.tasks.arn
    service_account_id = yandex_iam_service_account.service["trigger"].id
    batch_size         = "1"
    batch_cutoff       = "0"
  }

  function {
    id                 = yandex_function.worker.id
    service_account_id = yandex_iam_service_account.service["trigger"].id
  }

  depends_on = [
    yandex_resourcemanager_folder_iam_member.grant["trigger_queue"],
    yandex_resourcemanager_folder_iam_member.grant["trigger_call"],
  ]
}

resource "yandex_api_gateway" "archive" {
  name      = "${local.prefix}api"
  folder_id = var.folder_id

  spec = templatefile("${path.module}/openapi.yaml", {
    gateway_account_id = yandex_iam_service_account.service["gateway"].id
    folder_id          = var.folder_id
    queue_url          = yandex_message_queue.tasks.id
    database_path      = yandex_ydb_database_serverless.archives.database_path
    bucket_name        = yandex_storage_bucket.archives.bucket
  })

  depends_on = [
    terraform_data.archives_table,
    yandex_resourcemanager_folder_iam_member.grant["gateway_queue"],
    yandex_resourcemanager_folder_iam_member.grant["gateway_db"],
    yandex_resourcemanager_folder_iam_member.grant["gateway_files"],
  ]
}

output "api_url" {
  description = "Служебный HTTPS-адрес API-шлюза."
  value       = "https://${yandex_api_gateway.archive.domain}"
}
