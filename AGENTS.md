# Repository Guidelines

## Project Structure & Modules
- `terraform/`: IaC for Proxmox and Kubernetes
  - `prod/`: environment entrypoint (`main.tf`, `variables.tf`, `terraform.tfvars`)
  - `modules/`: reusable HCL modules (`proxmox/`, `kubernetes/`)
- `ansible/`: cluster bootstrap playbooks (`setup-master.yml`, `setup-worker.yml`, `inventory.yml`)
- `k8s/`: Flux/Kubernetes manifests (`apps/`, `flux/`)
- `.env` / `.envrc`: local environment; prefer `TF_VAR_…` exports.

## Build, Test, and Development
- Terraform (production env):
  - `cd terraform/prod`
  - `terraform init`: install providers
  - `terraform fmt -recursive`: format HCL
  - `terraform validate`: static checks
  - `terraform plan -var-file=terraform.tfvars`: preview changes
  - `terraform apply -var-file=terraform.tfvars`: apply changes
- Ansible (dry-run first):
  - `ansible-playbook -i ansible/inventory.yml ansible/setup-master.yml --check`
- Kubernetes/Flux:
  - Author manifests under `k8s/apps/<app>/`; Flux reconciles from Git.
  - Optional local check: `kubectl apply -k k8s/apps --dry-run=client`.

## Coding Style & Naming
- Indentation: 2 spaces (HCL, YAML). No tabs.
- Terraform: snake_case variables/outputs; module dirs kebab-case (`proxmox`, `kubernetes`). Run `terraform fmt`.
- Kubernetes: lowercase, kebab-case names (`release-bot`, `ingress-nginx`). Keep kustomize structure (`kustomization.yaml`).
- Ansible: YAML 2-space indent; group vars and host vars when applicable.

## Testing Guidelines
- Terraform: `validate` must pass; include a `plan` snippet in PRs for risky changes.
- Ansible: run with `--check` and, when possible, target a test host.
- Kubernetes: `kubectl kustomize k8s/apps` should render without error; prefer server-side dry runs.

## Commit & PR Guidelines
- Commits: Conventional Commits (e.g., `feat: ...`, `fix: ...`). Keep messages imperative and scoped.
- Branches: `feat/<scope>`, `fix/<scope>`, `chore/<scope>`.
- PRs must include:
  - What/why summary and affected paths (`terraform/prod`, `k8s/apps/<app>`, `ansible/...`).
  - Links to issues/changes; screenshots or logs when UI/cluster impact.
  - For Terraform: note `plan` outcome and any var changes (`TF_VAR_*`).

## Security & Config Tips
- Do not commit secrets or state; use `TF_VAR_*` and cluster secret managers (External Secrets). Review `.gitignore` before adding files.
- Rotate or revoke leaked tokens immediately and force Flux reconciliation if needed.
