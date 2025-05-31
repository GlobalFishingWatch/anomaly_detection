# Terraform Bootstrap

This directory creates the remote state bucket for the anomaly detection project using local Terraform state.

## Prerequisites

### 1. Set Up Project-Specific gcloud Configuration

```bash
# Create dedicated configuration for anomaly detection demo
gcloud config configurations create anomaly-demo
gcloud config configurations activate anomaly-demo
gcloud config set account christianhomberg@gmail.com
gcloud config set project anomaly-detection-demo-461518
```

### 2. Authenticate for Terraform

```bash
# Set up Application Default Credentials for Terraform
gcloud auth application-default login
# Follow browser prompts to authenticate as christianhomberg@gmail.com
```

### 3. Verify Configuration

```bash
# Verify active account and project
gcloud config get-value account
# Should show: christianhomberg@gmail.com

gcloud config get-value project  
# Should show: anomaly-detection-demo-461518
```

## Usage

```bash
# Initialize and create the state bucket
terraform init
terraform plan
terraform apply

# Output will show the bucket name for use in other modules
```

## What This Creates

- Google Cloud Storage bucket: `anomaly-detection-demo-461518-tfstate`
- Versioning enabled for state history
- Lifecycle rules for automatic cleanup
- Used by other Terraform modules for remote state storage

## Switching Configurations

To work on other projects later:

```bash
# Switch back to default or other configurations
gcloud config configurations activate default

# Return to anomaly demo project
gcloud config configurations activate anomaly-demo
```

## Troubleshooting

If you get authentication errors:
1. Ensure you're using the `anomaly-demo` configuration
2. Re-run `gcloud auth application-default login`
3. Verify the correct user with `gcloud config get-value account`