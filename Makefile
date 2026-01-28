PACKER_TEMPLATE ?= packer/dynatroni-debian12-arm64.pkr.hcl
CODEBUILD_ENV_OVERRIDES ?= $(DYNATRONI_CODEBUILD_ENV_OVERRIDES)

.PHONY: help packer-init packer-build codebuild-packer

help:
	@echo "Targets:"
	@echo "  packer-build      Build the AMI locally (env-driven)"
	@echo "  codebuild-packer  Trigger AWS CodeBuild (env-driven)"
	@echo ""
	@echo "Key env vars (local packer):"
	@echo "  DYNATRONI_AWS_REGION, DYNATRONI_SOURCE_AMI, DYNATRONI_INSTANCE_TYPE"
	@echo "  DYNATRONI_SSH_USERNAME, DYNATRONI_AMI_NAME, DYNATRONI_AMI_DESCRIPTION"
	@echo "  DYNATRONI_SUBNET_ID, DYNATRONI_SECURITY_GROUP_ID, DYNATRONI_IAM_INSTANCE_PROFILE"
	@echo "  DYNATRONI_AMI_TAGS_JSON (optional)"
	@echo ""
	@echo "Key env vars (CodeBuild):"
	@echo "  DYNATRONI_CODEBUILD_REGION, DYNATRONI_CODEBUILD_PROJECT"
	@echo "  DYNATRONI_CODEBUILD_SOURCE_VERSION (optional)"
	@echo "  DYNATRONI_CODEBUILD_ENV_OVERRIDES (optional)"

packer-init:
	@packer init $(PACKER_TEMPLATE)

packer-build: packer-init
	@packer build $(PACKER_TEMPLATE)

codebuild-packer:
	@aws codebuild start-build \
		--region "$${DYNATRONI_CODEBUILD_REGION}" \
		--project-name "$${DYNATRONI_CODEBUILD_PROJECT}" \
		$${DYNATRONI_CODEBUILD_SOURCE_VERSION:+--source-version "$${DYNATRONI_CODEBUILD_SOURCE_VERSION}"} \
		$${CODEBUILD_ENV_OVERRIDES:+--environment-variables-override $${CODEBUILD_ENV_OVERRIDES}}
