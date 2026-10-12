#!/usr/bin/env bash

cd "$(dirname "$0")/.."
exec docker compose exec db psql -U postgres -d bd2
