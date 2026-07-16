# CI/CD Finish Workflow

Goal: finish `0717-cicd-demo` with a green pipeline, GitOps manifest update, and reproducible deployment documentation.

## Success criteria

- GitHub Actions `test` and `build-and-update-manifest` are green.
- GHCR receives `latest` and immutable commit-SHA tags.
- The protected `main` branch is not mutated by the deploy job.
- The unprotected `gitops` branch receives the image SHA automatically.
- ArgoCD targets `gitops/k8s`.
- `WRITEUP.md` contains step-by-step build, deploy, rollback, validation, and debug records.
- se218.net blockers and required operator commands are explicit.

## Work packets

- Main agent: pipeline correction, GitHub settings, Actions/GitOps verification, integration.
- Docs agent: create `WRITEUP.md` only; do not edit implementation files.

## Risks and gates

- External GitHub writes are user-authorized for this repo.
- No se218.net server access is available; production host changes remain manual.
- Never store CLI tokens or private keys in the repo.

## Verification

- Inspect Actions jobs and failed logs with `gh`.
- Compare main SHA with the image SHA committed to `gitops`.
- Confirm branch protection requires `test`.
- Read back and link-check the final documents.
