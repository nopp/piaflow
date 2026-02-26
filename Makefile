.PHONY: run run-dev run-prod build test tidy

run: run-dev

# Local development: SQLite (data/cicd.db)
run-dev:
	go run ./cmd/cicd

# Production: MySQL. Set DB_DSN (and optionally DB_DRIVER=mysql) before running, e.g.:
#   export DB_DSN='user:password@tcp(host:3306)/dbname?parseTime=true'
#   make run-prod
# Or use a .env file: source config/database.env && make run-prod
run-prod:
	@if [ -z "$$DB_DSN" ]; then echo "Error: set DB_DSN for MySQL (e.g. export DB_DSN='user:pass@tcp(host:3306)/dbname?parseTime=true')"; exit 1; fi
	DB_DRIVER=mysql go run ./cmd/cicd

build:
	go build -o bin/cicd ./cmd/cicd

test:
	go test ./...

tidy:
	go mod tidy
