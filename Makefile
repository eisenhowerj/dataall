help:
	@echo "install - install a virtualenv for development"
	@echo "lint - check source code with flake8"
	@echo "test - run unit tests"
	@echo "coverage - check code coverage"
	@echo "build env={env} - package new code and update the function in the cloud"
	@echo "describe env={env} - describe cloud stack"
	@echo "check env={env} - check the state of one function"
	@echo "clean - remove build, test, coverage and Python artifacts locally"
	@echo "tear-down env={env} - completely destroy stack in the cloud -- be cautious"

UV_VERSION := 0.11.8

.PHONY: venv .ensure-uv
venv:
	@test -d "venv" || mkdir -p "venv"
	@rm -Rf "venv"
	@python3 -m venv "venv"
	@/bin/bash -c "source venv/bin/activate"

# Bootstrap: install uv at a pinned version if not already present
.ensure-uv:
	@command -v uv >/dev/null 2>&1 || pip install uv==$(UV_VERSION)

install: .ensure-uv install-deploy install-backend install-cdkproxy install-tests install-integration-tests install-custom-auth

install-deploy: .ensure-uv
	uv sync --group deploy

install-backend: .ensure-uv
	uv sync

install-cdkproxy: .ensure-uv
	uv sync --group cdkproxy

install-tests: .ensure-uv
	uv sync --group test

install-integration-tests: .ensure-uv
	uv sync --group integration

install-custom-auth:
	pip install -r deploy/custom_resources/custom_authorizer/requirements.txt

lint: .ensure-uv
	uvx ruff check --fix
	uvx ruff format

bandit: .ensure-uv
	uvx bandit -r backend/ | tee bandit.log || true

check-security: .ensure-uv install-backend install-cdkproxy
	uvx bandit -lll -r backend
	uvx safety check

checkov-synth: .ensure-uv install-backend install-cdkproxy install-tests
	export PYTHONPATH=./backend:/./tests && \
	uv run python -m pytest -v -ra -k test_checkov tests

test: .ensure-uv
	export PYTHONPATH=./backend:/./tests && \
	uv run python -m pytest -v -ra tests/

integration-tests: .ensure-uv install-integration-tests
	export PYTHONPATH=./backend:/./tests_new && \
	uv run python -m pytest -x -v -ra tests_new/integration_tests/ \
		--junitxml=reports/integration_tests.xml

coverage: .ensure-uv install-backend install-cdkproxy install-tests
	export PYTHONPATH=./backend:/./tests && \
	uv run python -m pytest -x -v -ra tests/ \
		--junitxml=reports/test-unit.xml \
		--cov-report xml:cobertura.xml \
		--cov-report term-missing \
		--cov-report html \
		--cov=backend/dataall \
		--cov-config=.coveragerc \
		--color=yes

deploy-image:
	docker build ${build-args} -f backend/docker/prod/${type}/Dockerfile -t ${image-tag}:${image-tag} . && \
	aws ecr get-login-password --region ${region} | docker login --username AWS --password-stdin ${account}.dkr.ecr.${region}.amazonaws.com && \
	docker tag ${image-tag}:${image-tag} ${account}.dkr.ecr.${region}.amazonaws.com/${repo}:${image-tag} && \
	docker push ${account}.dkr.ecr.${region}.amazonaws.com/${repo}:${image-tag}

assume-role:
	aws sts assume-role --role-arn "arn:aws:iam::${REMOTE_ACCOUNT_ID}:role/${REMOTE_ROLE}" --external-id ${EXTERNAL_ID} --role-session-name "session1" >.assume_role_json
	echo "export AWS_ACCESS_KEY_ID=$$(cat .assume_role_json | jq '.Credentials.AccessKeyId' -r)" >.env.assumed_role
	echo "export AWS_SECRET_ACCESS_KEY=$$(cat .assume_role_json | jq '.Credentials.SecretAccessKey' -r)" >>.env.assumed_role
	echo "export AWS_SESSION_TOKEN=$$(cat .assume_role_json | jq '.Credentials.SessionToken' -r)" >>.env.assumed_role
	rm .assume_role_json

drop-tables: .ensure-uv install-backend
	export PYTHONPATH=./backend && \
	uv run python backend/migrations/drop_tables.py

upgrade-db: .ensure-uv install-backend
	export PYTHONPATH=./backend && \
	uv run alembic -c backend/alembic.ini upgrade head

history-db: .ensure-uv install-backend
	export PYTHONPATH=./backend && \
	uv run alembic -c backend/alembic.ini history

generate-migrations: .ensure-uv install-backend
	export PYTHONPATH=./backend && \
	uv run alembic -c backend/alembic.ini upgrade head
	uv run alembic -c backend/alembic.ini revision -m "describe_changes_shortly" --autogenerate

clean:
	@rm -fr cdk_out/
	@rm -fr dist/
	@rm -fr htmlcov/
	@rm -fr site/
	@rm -fr .eggs/
	@rm -fr cdk_out/
	@rm -fr .tox/
	@find . -name '*.egg-info' -exec rm -fr {} +
	@find . -name "*.py[co]" -o -name .pytest_cache -exec rm -rf {} +
	@find . -name '*.egg' -exec rm -f {} +
	@find . -name '*.pyc' -exec rm -f {} +
	@find . -name '*.pyo' -exec rm -f {} +
	@find . -name '*~' -exec rm -f {} +
	@find . -name '__pycache__' -exec rm -fr {} +
