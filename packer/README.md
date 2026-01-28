<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="300">
</p>

# Dynatroni Packer Build

This folder contains a minimal Packer build that installs Patroni + Dynatroni
and drops example config/systemd files.

## Required Env Vars

Set these before running `packer build`:

- `DYNATRONI_AWS_REGION`
- `DYNATRONI_SOURCE_AMI`
- `DYNATRONI_INSTANCE_TYPE`
- `DYNATRONI_SSH_USERNAME`
- `DYNATRONI_AMI_NAME`
- `DYNATRONI_AMI_DESCRIPTION`
- `DYNATRONI_SUBNET_ID`
- `DYNATRONI_SECURITY_GROUP_ID`
- `DYNATRONI_IAM_INSTANCE_PROFILE`
- `DYNATRONI_AMI_TAGS_JSON` (optional, JSON map)

## Notes

- The service is installed but not enabled by the template.
- `dynatroni-configure.sh` uses env vars at boot to render `/etc/patroni/patroni.yml`.
  Update the template or the script to match your deployment.
- This template does not install PostgreSQL itself; add that to the build if you want a complete Patroni node AMI.
