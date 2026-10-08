# AWS access: IAM Identity Center instead of root

Day-to-day work (Terraform, `scripts/bootstrap-cluster.sh`) runs on short-lived
credentials from IAM Identity Center. The root user is reserved for the few
tasks only root can do. Neither the script nor Terraform hardcodes credentials;
both read them from `AWS_PROFILE`.

## One-time setup (console, signed in as root)

1. **Organizations**: create an organization. This account becomes the
   management account, and Identity Center needs one.
2. **IAM Identity Center**: Enable (ours lives in `us-east-1`; its region only
   hosts the portal and users, resources stay in `eu-central-1`), keeping *Identity Center
   directory* as the identity source.
3. **Settings → Authentication**: require MFA at every sign-in.
4. **Users**: create yourself and accept the invitation email (set a password
   and register MFA).
5. **Permission sets**: create `AdministratorAccess` from the predefined
   policy, with an 8h session duration.
6. **AWS accounts**: assign your user to this account with `AdministratorAccess`.

## Local CLI

```sh
aws configure sso          # start URL: Identity Center dashboard -> AWS access portal URL
                           # SSO region: us-east-1 (where Identity Center lives)
                           # CLI default region: eu-central-1, profile name: url-shortener
aws sso login --profile url-shortener
export AWS_PROFILE=url-shortener

aws sts get-caller-identity   # Arn must be ...assumed-role/AWSReservedSSO_AdministratorAccess_.../<you>
                              # never ...:root
```

Check that everything still works on the new identity:

```sh
terraform -chdir=envs/dev plan   # state bucket readable, plan as expected
scripts/bootstrap-cluster.sh     # SSM, tunnel, ArgoCD
```

## Locking root away

Only do this once the checks above pass:

- IAM → Security credentials (root): delete every **access key**.
- Enable MFA on root (passkey or hardware key), and store the password and
  recovery details offline.
- From now on, sign in as root only for root-only tasks (closing the account,
  changing the support plan, restoring access to Identity Center).
